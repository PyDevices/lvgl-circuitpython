/**
 * @file lv_jpegio_decoder_circuitpython.c
 *
 * LVGL JPEG decoder for CircuitPython, backed by CircuitPython's own TJpgDec
 * (lib/tjpgd -- the copy `jpegio` decodes with).
 *
 * One TJpgDec per firmware (docs/jpegio-vision.md, Phase 2, no LVGL fork):
 * lvgl-bindings' lv_conf.h sets LV_USE_TJPGD 0 on CircuitPython, so LVGL's
 * libs/tjpgd compiles to nothing, and this file registers a decoder through
 * LVGL's public lv_image_decoder_create API instead -- the same registration
 * lv_tjpgd.c performs (lvgl/src/libs/tjpgd/lv_tjpgd.c, lv_tjpgd_init).
 *
 * Contract:
 *  - Sniff is SOI only (FF D8) for both source kinds; jd_prepare judges the
 *    rest, so a UVC MJPEG frame that is not JFIF-first (SOI DQT SOF0 DHT ...)
 *    is accepted where LVGL's is_jpg() would refuse it. Baseline JPEG only:
 *    progressive, DHT-less and truncated frames fail in jd_prepare / jd_decomp
 *    and the open fails.
 *  - Output is exactly what CircuitPython's jpegio produces (decision D2):
 *    CP's lib/tjpgd/src/tjpgd.c byte-swaps its RGB565 (`__builtin_bswap16` in
 *    mcu_output), so the decoded image is labelled
 *    LV_COLOR_FORMAT_RGB565_SWAPPED with a tight stride of w * 2. LVGL's
 *    software renderer swaps it back when blending onto an RGB565 display
 *    (lv_draw_sw_blend_to_rgb565.c, rgb565_swapped_image_blend).
 *  - Scale 0 only. The whole frame is decoded in open_cb into one draw buffer
 *    (like lv_lodepng.c); there is no get_area_cb.
 *  - Sources: LV_IMAGE_SRC_VARIABLE (an lv_image_dsc_t whose `data` holds the
 *    JPEG bytes; its header w/h/cf are not trusted, jd_prepare's are used) and
 *    LV_IMAGE_SRC_FILE (any lv_fs path whose first two bytes are FF D8 -- the
 *    extension is not consulted, the rule displayif's shim applies on
 *    MicroPython, so an extension-less camera dump decodes on both runtimes).
 *
 * Built only when CIRCUITPY_JPEGIO is 1, which is exactly when CircuitPython
 * compiles lib/tjpgd/src/tjpgd.c (py/circuitpy_defns.mk: `ifeq
 * ($(CIRCUITPY_JPEGIO),1) SRC_MOD += lib/tjpgd/src/tjpgd.c`; the unix coverage
 * variant adds it and -DCIRCUITPY_JPEGIO=1 itself). Ports that include
 * py/circuitpy_mpconfig.mk always define it (0 or 1); the unix port does not
 * include that file, so the guard also tolerates an undefined macro. Without
 * jpegio the two entry points are no-ops and the build still links -- it just
 * has no JPEG decoder for LVGL.
 */

/*********************
 *      INCLUDES
 *********************/
#include "lvgl/lvgl.h"
#include "lvgl/src/lvgl_private.h"

/*********************
 *  GLOBAL PROTOTYPES
 *********************/
/* Called by the CircuitPython spike (src/circuitpython_spike/shared-module/
 * lvgl/__init__.c) right after lv_init() / before lv_deinit(). Declared here,
 * and as externs there, the way mp_lv_deinit_gc is. */
void lv_jpegio_decoder_circuitpython_init(void);
void lv_jpegio_decoder_circuitpython_deinit(void);

#if defined(CIRCUITPY_JPEGIO) && CIRCUITPY_JPEGIO

#include "lib/tjpgd/src/tjpgd.h"

#if JD_FORMAT != 1
#error "lv_jpegio_decoder_circuitpython.c expects CircuitPython's tjpgdcnf.h (JD_FORMAT 1, RGB565)"
#endif
#if LV_USE_TJPGD
#error "LV_USE_TJPGD must be 0 on CircuitPython: lib/tjpgd already defines jd_prepare/jd_decomp, and this file is LVGL's JPEG decoder"
#endif

/*********************
 *      DEFINES
 *********************/

#define DECODER_NAME "jpegio"

/* CircuitPython's own work-area size for this TJpgDec configuration
 * (shared-module/jpegio/JpegDecoder.h, TJPGD_WORKSPACE_SIZE): the 512-byte
 * stream buffer, the quantiser and Huffman tables, and the MCU + IDCT scratch
 * for a 16x16 (4:2:0) MCU. Heap-allocated per open (never on the stack). */
#define JPEGIO_LV_WORKSPACE_SIZE 3500

/**********************
 *      TYPEDEFS
 **********************/

/* jd->device for one decode: the input (memory or lv_fs) and the output. */
typedef struct {
    const uint8_t * data;   /* LV_IMAGE_SRC_VARIABLE: unread remainder of the JPEG bytes */
    size_t remaining;
    lv_fs_file_t * file;    /* LV_IMAGE_SRC_FILE: open file, else NULL */
    lv_draw_buf_t * out;    /* RGB565_SWAPPED destination, set before jd_decomp */
} jpegio_lv_ctx_t;

/**********************
 *  STATIC PROTOTYPES
 **********************/
static lv_result_t decoder_info(lv_image_decoder_t * decoder, lv_image_decoder_dsc_t * dsc, lv_image_header_t * header);
static lv_result_t decoder_open(lv_image_decoder_t * decoder, lv_image_decoder_dsc_t * dsc);
static void decoder_close(lv_image_decoder_t * decoder, lv_image_decoder_dsc_t * dsc);
static size_t input_func(JDEC * jd, uint8_t * buff, size_t ndata);
static int output_func(JDEC * jd, void * bitmap, JRECT * rect);
static bool has_soi(const uint8_t * data, size_t len);
static bool file_has_soi(lv_fs_file_t * file);
static JRESULT prepare(JDEC * jd, void ** pool, jpegio_lv_ctx_t * ctx);
static lv_image_decoder_t * find_registered(void);

/**********************
 *   GLOBAL FUNCTIONS
 **********************/

/**
 * Register the decoder. Idempotent: lv_init() may run more than once without
 * an lv_deinit() in between (LVGL's lv_init returns early then), and this must
 * not add a second decoder each time.
 */
void lv_jpegio_decoder_circuitpython_init(void)
{
    if(find_registered() != NULL) return;

    lv_image_decoder_t * dec = lv_image_decoder_create();
    if(dec == NULL) {
        LV_LOG_ERROR("jpegio: lv_image_decoder_create failed");
        return;
    }
    lv_image_decoder_set_info_cb(dec, decoder_info);
    lv_image_decoder_set_open_cb(dec, decoder_open);
    lv_image_decoder_set_close_cb(dec, decoder_close);
    dec->name = DECODER_NAME;
}

/**
 * Unregister the decoder (lv_deinit() also clears the decoder list; this keeps
 * the pair symmetric and safe to call in either order).
 */
void lv_jpegio_decoder_circuitpython_deinit(void)
{
    lv_image_decoder_t * dec = find_registered();
    if(dec != NULL) lv_image_decoder_delete(dec);
}

/**********************
 *   STATIC FUNCTIONS
 **********************/

static lv_image_decoder_t * find_registered(void)
{
    if(!lv_is_initialized()) return NULL;
    lv_image_decoder_t * dec = NULL;
    while((dec = lv_image_decoder_get_next(dec)) != NULL) {
        if(dec->info_cb == decoder_info) return dec;
    }
    return NULL;
}

static bool has_soi(const uint8_t * data, size_t len)
{
    return data != NULL && len >= 2 && data[0] == 0xFF && data[1] == 0xD8;
}

/* File-source sniff, the same SOI-only rule as variable sources: the first two
 * bytes must be FF D8. The name's extension is not consulted (an extension-less
 * camera dump decodes; a ".jpg" that is not a JPEG is not claimed), which is
 * what displayif's shim does on MicroPython too. Leaves the file at offset 0. */
static bool file_has_soi(lv_fs_file_t * file)
{
    uint8_t soi[2];
    uint32_t rn = 0;
    if(lv_fs_seek(file, 0, LV_FS_SEEK_SET) != LV_FS_RES_OK) return false;
    if(lv_fs_read(file, soi, sizeof(soi), &rn) != LV_FS_RES_OK) return false;
    if(!has_soi(soi, rn)) return false;
    return lv_fs_seek(file, 0, LV_FS_SEEK_SET) == LV_FS_RES_OK;
}

/* TJpgDec stream input: fill `buff` with up to `ndata` bytes, or skip `ndata`
 * bytes when `buff` is NULL. Memory sources hand out the caller's bytes;
 * file sources read / seek through lv_fs (tell + SEEK_SET, like lv_tjpgd.c,
 * so a driver without SEEK_CUR works). */
static size_t input_func(JDEC * jd, uint8_t * buff, size_t ndata)
{
    jpegio_lv_ctx_t * ctx = jd->device;
    if(ctx->file != NULL) {
        if(buff != NULL) {
            uint32_t rn = 0;
            if(lv_fs_read(ctx->file, buff, (uint32_t)ndata, &rn) != LV_FS_RES_OK) return 0;
            return rn;
        }
        uint32_t pos = 0;
        if(lv_fs_tell(ctx->file, &pos) != LV_FS_RES_OK) return 0;
        if(lv_fs_seek(ctx->file, (uint32_t)(pos + ndata), LV_FS_SEEK_SET) != LV_FS_RES_OK) return 0;
        return ndata;
    }
    size_t n = ndata < ctx->remaining ? ndata : ctx->remaining;
    if(buff != NULL) lv_memcpy(buff, ctx->data, n);
    ctx->data += n;
    ctx->remaining -= n;
    return n;
}

/* TJpgDec output: one MCU-sized rectangle of RGB565_SWAPPED pixels, packed at
 * (right - left + 1) pixels per row. Copy it into the draw buffer at its place.
 * Returning 0 aborts the decode with JDR_INTR. */
static int output_func(JDEC * jd, void * bitmap, JRECT * rect)
{
    jpegio_lv_ctx_t * ctx = jd->device;
    lv_draw_buf_t * out = ctx->out;
    if(out == NULL) return 0;
    if(rect->right >= out->header.w || rect->bottom >= out->header.h) return 0;   /* never, at scale 0 */

    uint32_t bw = (uint32_t)rect->right - rect->left + 1;
    uint32_t bh = (uint32_t)rect->bottom - rect->top + 1;
    const uint8_t * src = bitmap;
    uint32_t r;
    for(r = 0; r < bh; r++) {
        uint8_t * dst = out->data + ((uint32_t)rect->top + r) * out->header.stride + (uint32_t)rect->left * 2;
        lv_memcpy(dst, src, bw * 2);
        src += bw * 2;
    }
    return 1;
}

/* jd_prepare with a heap work area. On any return *pool is either NULL or
 * owned by the caller. */
static JRESULT prepare(JDEC * jd, void ** pool, jpegio_lv_ctx_t * ctx)
{
    *pool = lv_malloc(JPEGIO_LV_WORKSPACE_SIZE);
    if(*pool == NULL) return JDR_MEM1;
    return jd_prepare(jd, input_func, *pool, JPEGIO_LV_WORKSPACE_SIZE, ctx);
}

/* Fill `ctx` from the descriptor's source. For LV_IMAGE_SRC_FILE the caller
 * supplies the open file (lv_image_decoder opens dsc->file for info; open_cb
 * opens its own). */
static bool ctx_from_src(lv_image_decoder_dsc_t * dsc, jpegio_lv_ctx_t * ctx, lv_fs_file_t * file)
{
    lv_memzero(ctx, sizeof(*ctx));
    if(dsc->src_type == LV_IMAGE_SRC_VARIABLE) {
        const lv_image_dsc_t * img_dsc = dsc->src;
        if(!has_soi(img_dsc->data, img_dsc->data_size)) return false;
        ctx->data = img_dsc->data;
        ctx->remaining = img_dsc->data_size;
        return true;
    }
    if(dsc->src_type == LV_IMAGE_SRC_FILE) {
        if(file == NULL || !file_has_soi(file)) return false;
        ctx->file = file;
        return true;
    }
    return false;
}

static lv_result_t decoder_info(lv_image_decoder_t * decoder, lv_image_decoder_dsc_t * dsc, lv_image_header_t * header)
{
    LV_UNUSED(decoder);

    jpegio_lv_ctx_t ctx;
    if(!ctx_from_src(dsc, &ctx, &dsc->file)) return LV_RESULT_INVALID;

    /* jd_prepare parses the headers only (up to SOS): the true size, and a
     * refusal for anything TJpgDec cannot decode, before any pixel work. */
    JDEC jd;
    void * pool = NULL;
    JRESULT rc = prepare(&jd, &pool, &ctx);
    lv_free(pool);
    if(rc != JDR_OK) {
        LV_LOG_WARN("jpegio: jd_prepare error %d", (int)rc);
        return LV_RESULT_INVALID;
    }

    header->cf = LV_COLOR_FORMAT_RGB565_SWAPPED;
    header->w = jd.width;
    header->h = jd.height;
    header->stride = (uint32_t)jd.width * 2;
    return LV_RESULT_OK;
}

static lv_result_t decoder_open(lv_image_decoder_t * decoder, lv_image_decoder_dsc_t * dsc)
{
    jpegio_lv_ctx_t ctx;
    lv_fs_file_t file;
    bool file_open = false;

    if(dsc->src_type == LV_IMAGE_SRC_FILE) {
        if(lv_fs_open(&file, dsc->src, LV_FS_MODE_RD) != LV_FS_RES_OK) return LV_RESULT_INVALID;
        file_open = true;
    }
    if(!ctx_from_src(dsc, &ctx, &file)) {
        if(file_open) lv_fs_close(&file);
        return LV_RESULT_INVALID;
    }

    JDEC jd;
    void * pool = NULL;
    lv_draw_buf_t * decoded = NULL;
    JRESULT rc = prepare(&jd, &pool, &ctx);
    if(rc == JDR_OK) {
        /* stride 0: LVGL computes it; with LV_DRAW_BUF_STRIDE_ALIGN 1 that is w * 2 */
        decoded = lv_draw_buf_create(jd.width, jd.height, LV_COLOR_FORMAT_RGB565_SWAPPED, 0);
        if(decoded == NULL) {
            LV_LOG_WARN("jpegio: no memory for a %ux%u RGB565 image", (unsigned)jd.width, (unsigned)jd.height);
            rc = JDR_MEM1;
        }
        else {
            ctx.out = decoded;
            rc = jd_decomp(&jd, output_func, 0);
        }
    }
    lv_free(pool);
    if(file_open) lv_fs_close(&file);

    if(rc != JDR_OK) {
        LV_LOG_WARN("jpegio: decode error %d", (int)rc);
        if(decoded != NULL) lv_draw_buf_destroy(decoded);
        return LV_RESULT_INVALID;
    }

    /* From here on the shape is lv_lodepng.c's: post-process, then hand the
     * buffer to the image cache when it is enabled, else keep it until close. */
    lv_draw_buf_t * adjusted = lv_image_decoder_post_process(dsc, decoded);
    if(adjusted == NULL) {
        lv_draw_buf_destroy(decoded);
        return LV_RESULT_INVALID;
    }
    if(adjusted != decoded) {
        lv_draw_buf_destroy(decoded);
        decoded = adjusted;
    }
    dsc->decoded = decoded;

    if(dsc->args.no_cache) return LV_RESULT_OK;
    if(!lv_image_cache_is_enabled()) return LV_RESULT_OK;

    lv_image_cache_data_t search_key;
    search_key.src_type = dsc->src_type;
    search_key.src = dsc->src;
    search_key.slot.size = decoded->data_size;

    lv_cache_entry_t * entry = lv_image_decoder_add_to_cache(decoder, &search_key, decoded, NULL);
    if(entry == NULL) {
        lv_draw_buf_destroy(decoded);
        dsc->decoded = NULL;
        return LV_RESULT_INVALID;
    }
    dsc->cache_entry = entry;
    return LV_RESULT_OK;
}

static void decoder_close(lv_image_decoder_t * decoder, lv_image_decoder_dsc_t * dsc)
{
    LV_UNUSED(decoder);
    if(dsc->args.no_cache || !lv_image_cache_is_enabled()) {
        lv_draw_buf_destroy((lv_draw_buf_t *)dsc->decoded);
    }
}

#else /* !CIRCUITPY_JPEGIO */

/* No lib/tjpgd in this build: nothing to register, and nothing to link against. */
void lv_jpegio_decoder_circuitpython_init(void)
{
}

void lv_jpegio_decoder_circuitpython_deinit(void)
{
}

#endif /* CIRCUITPY_JPEGIO */
