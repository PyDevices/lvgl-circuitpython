/* Host proof of lvgl-circuitpython's jpegio decoder shim without a CircuitPython
 * build: LVGL v9.5.0 (lvgl-bindings pin, CircuitPython lv_conf.h) + CircuitPython's
 * lib/tjpgd/src/tjpgd.c + src/lv_jpegio_decoder_circuitpython.c, linked on the
 * host with a malloc allocator twin.
 *
 *   host_check <outdir> <frame.jpg>...
 *
 * For every frame: register check, lv_image_decoder_get_info header (cf must be
 * RGB565_SWAPPED), which decoder opened it, lv_image on a 320x240 native RGB565
 * display with a capturing flush_cb, the widget size, and the cropped frame
 * written to <outdir>/var_<name>.rgb565 (variable source, header w/h = 0) and
 * <outdir>/file_<name>.rgb565 (file source through a stdio lv_fs driver, 'P:').
 * Exit status is non-zero if any frame that jd_prepare accepts fails to render.
 */
#include "lvgl/lvgl.h"
#include "lvgl/src/lvgl_private.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void lv_jpegio_decoder_circuitpython_init(void);
void lv_jpegio_decoder_circuitpython_deinit(void);

#define W 320
#define H 240
static uint8_t frame[W * H * 2];
static int flushes;

static void flush_cb(lv_display_t *d, const lv_area_t *a, uint8_t *px)
{
    int w = a->x2 - a->x1 + 1, h = a->y2 - a->y1 + 1;
    for(int r = 0; r < h; r++)
        memcpy(frame + ((a->y1 + r) * W + a->x1) * 2, px + r * w * 2, w * 2);
    flushes++;
    lv_display_flush_ready(d);
}

static void log_cb(lv_log_level_t level, const char *buf)
{
    LV_UNUSED(level);
    fputs(buf, stderr);
}

/* stdio lv_fs driver, letter 'P': "P:/abs/path" -> fopen("/abs/path") */
static void *fs_open(lv_fs_drv_t *drv, const char *path, lv_fs_mode_t mode)
{
    LV_UNUSED(drv);
    return mode == LV_FS_MODE_RD ? fopen(path, "rb") : NULL;
}
static lv_fs_res_t fs_close(lv_fs_drv_t *drv, void *f) { LV_UNUSED(drv); fclose(f); return LV_FS_RES_OK; }
static lv_fs_res_t fs_read(lv_fs_drv_t *drv, void *f, void *buf, uint32_t btr, uint32_t *br)
{
    LV_UNUSED(drv);
    *br = (uint32_t)fread(buf, 1, btr, f);
    return LV_FS_RES_OK;
}
static lv_fs_res_t fs_seek(lv_fs_drv_t *drv, void *f, uint32_t pos, lv_fs_whence_t whence)
{
    LV_UNUSED(drv);
    int w = whence == LV_FS_SEEK_SET ? SEEK_SET : whence == LV_FS_SEEK_CUR ? SEEK_CUR : SEEK_END;
    return fseek(f, (long)pos, w) == 0 ? LV_FS_RES_OK : LV_FS_RES_UNKNOWN;
}
static lv_fs_res_t fs_tell(lv_fs_drv_t *drv, void *f, uint32_t *pos)
{
    LV_UNUSED(drv);
    *pos = (uint32_t)ftell(f);
    return LV_FS_RES_OK;
}

static int count_named(const char *name)
{
    int n = 0;
    lv_image_decoder_t *dec = NULL;
    while((dec = lv_image_decoder_get_next(dec)) != NULL)
        if(dec->name && strcmp(dec->name, name) == 0) n++;
    return n;
}

static void list_decoders(void)
{
    lv_image_decoder_t *dec = NULL;
    fprintf(stdout, "decoders:");
    while((dec = lv_image_decoder_get_next(dec)) != NULL)
        fprintf(stdout, " %s", dec->name ? dec->name : "(unnamed)");
    fprintf(stdout, "\n");
}

static const char *base(const char *p)
{
    const char *s = strrchr(p, '/');
    return s ? s + 1 : p;
}

static lv_display_t *disp;

/* render `src` (dsc pointer or "P:..." path); returns widget w/h, writes crop */
static int render(const void *src, const char *label, const char *outpath, int *ow, int *oh)
{
    lv_obj_t *scr = lv_obj_create(NULL);
    lv_obj_set_style_pad_all(scr, 0, 0);
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x123456), 0);
    lv_screen_load(scr);
    lv_obj_t *img = lv_image_create(scr);
    lv_image_set_src(img, src);
    lv_obj_set_pos(img, 0, 0);
    lv_obj_update_layout(scr);
    int w = lv_obj_get_width(img), h = lv_obj_get_height(img);
    memset(frame, 0xA5, sizeof frame);
    flushes = 0;
    lv_refr_now(disp);
    *ow = w;
    *oh = h;
    if(w <= 0 || h <= 0) {
        fprintf(stdout, "%-6s %-36s widget %dx%d (refused), flushes %d\n", label, base(outpath), w, h, flushes);
        return 0;
    }
    FILE *f = fopen(outpath, "wb");
    if(!f) { perror(outpath); return 1; }
    for(int r = 0; r < h; r++) fwrite(frame + r * W * 2, 1, (size_t)w * 2, f);
    fclose(f);
    fprintf(stdout, "%-6s %-36s widget %dx%d, flushes %d -> %s\n", label, base(outpath), w, h, flushes, outpath);
    return 0;
}

int main(int argc, char **argv)
{
    if(argc < 3) { fprintf(stderr, "usage: %s outdir frame.jpg...\n", argv[0]); return 2; }
    const char *outdir = argv[1];
    int rc = 0;

    lv_init();
    lv_log_register_print_cb(log_cb);
    lv_jpegio_decoder_circuitpython_init();
    lv_jpegio_decoder_circuitpython_init();   /* idempotency: still one */
    fprintf(stdout, "jpegio decoders registered after init x2: %d\n", count_named("jpegio"));
    if(count_named("jpegio") != 1) rc = 1;
    list_decoders();

    static lv_fs_drv_t drv;
    lv_fs_drv_init(&drv);
    drv.letter = 'P';
    drv.open_cb = fs_open;
    drv.close_cb = fs_close;
    drv.read_cb = fs_read;
    drv.seek_cb = fs_seek;
    drv.tell_cb = fs_tell;
    lv_fs_drv_register(&drv);

    disp = lv_display_create(W, H);
    lv_display_set_flush_cb(disp, flush_cb);
    lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
    lv_draw_buf_t *buf = lv_draw_buf_create(W, H, LV_COLOR_FORMAT_RGB565, 0);
    lv_display_set_draw_buffers(disp, buf, NULL);
    lv_display_set_render_mode(disp, LV_DISPLAY_RENDER_MODE_PARTIAL);

    for(int i = 2; i < argc; i++) {
        const char *path = argv[i];
        FILE *f = fopen(path, "rb");
        if(!f) { perror(path); rc = 1; continue; }
        fseek(f, 0, SEEK_END);
        long n = ftell(f);
        fseek(f, 0, SEEK_SET);
        uint8_t *data = malloc((size_t)n);
        if(fread(data, 1, (size_t)n, f) != (size_t)n) { perror(path); rc = 1; fclose(f); free(data); continue; }
        fclose(f);

        lv_image_dsc_t dsc;
        memset(&dsc, 0, sizeof dsc);
        dsc.header.magic = LV_IMAGE_HEADER_MAGIC;
        dsc.header.cf = LV_COLOR_FORMAT_UNKNOWN;   /* the bin decoder rejects UNKNOWN, so only the jpegio decoder can accept this */
        dsc.header.w = 0;   /* deliberately not the real size: the decoder must report it */
        dsc.header.h = 0;
        dsc.data_size = (uint32_t)n;
        dsc.data = data;

        lv_image_header_t hdr;
        lv_result_t ir = lv_image_decoder_get_info(&dsc, &hdr);
        fprintf(stdout, "%-36s %ld bytes: get_info %s w=%u h=%u cf=0x%02x stride=%u\n", base(path), n,
                ir == LV_RESULT_OK ? "OK" : "INVALID", (unsigned)hdr.w, (unsigned)hdr.h, (unsigned)hdr.cf, (unsigned)hdr.stride);

        lv_image_decoder_dsc_t ddsc;
        lv_result_t orr = lv_image_decoder_open(&ddsc, &dsc, NULL);
        fprintf(stdout, "%-36s open %s by decoder %s; decoded cf=0x%02x %ux%u stride %u data_size %u\n", base(path),
                orr == LV_RESULT_OK ? "OK" : "INVALID", orr == LV_RESULT_OK && ddsc.decoder ? ddsc.decoder->name : "-",
                orr == LV_RESULT_OK && ddsc.decoded ? (unsigned)ddsc.decoded->header.cf : 0,
                orr == LV_RESULT_OK && ddsc.decoded ? (unsigned)ddsc.decoded->header.w : 0,
                orr == LV_RESULT_OK && ddsc.decoded ? (unsigned)ddsc.decoded->header.h : 0,
                orr == LV_RESULT_OK && ddsc.decoded ? (unsigned)ddsc.decoded->header.stride : 0,
                orr == LV_RESULT_OK && ddsc.decoded ? (unsigned)ddsc.decoded->data_size : 0);
        if(orr == LV_RESULT_OK) lv_image_decoder_close(&ddsc);

        char out[1024];
        int w, h;
        snprintf(out, sizeof out, "%s/var_%s.rgb565", outdir, base(path));
        rc |= render(&dsc, "var", out, &w, &h);
        if(ir == LV_RESULT_OK && (w != (int)hdr.w || h != (int)hdr.h)) { fprintf(stdout, "  MISMATCH: widget size != decoder size\n"); rc = 1; }

        char fpath[1100];
        snprintf(fpath, sizeof fpath, "P:%s", path);
        snprintf(out, sizeof out, "%s/file_%s.rgb565", outdir, base(path));
        rc |= render(fpath, "file", out, &w, &h);
        if(ir == LV_RESULT_OK && (w != (int)hdr.w || h != (int)hdr.h)) { fprintf(stdout, "  MISMATCH: file-source widget size != decoder size\n"); rc = 1; }
        free(data);
    }

    lv_jpegio_decoder_circuitpython_deinit();
    fprintf(stdout, "jpegio decoders after deinit: %d\n", count_named("jpegio"));
    lv_deinit();
    lv_init();
    lv_jpegio_decoder_circuitpython_init();
    fprintf(stdout, "jpegio decoders after lv_deinit/lv_init/register: %d\n", count_named("jpegio"));
    if(count_named("jpegio") != 1) rc = 1;
    return rc;
}
