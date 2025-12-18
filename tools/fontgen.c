#include <cairo.h>
#include <cairo-ft.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// Output file
FILE *out;

// Helper to write Zig header
void write_header() {
    fprintf(out, "const std = @import(\"std\");\n\n");
    fprintf(out, "pub const Glyph = struct {\n");
    fprintf(out, "    width: u16,\n");
    fprintf(out, "    height: u16,\n");
    fprintf(out, "    advance_x: u16,\n");
    fprintf(out, "    bearing_x: i16,\n");
    fprintf(out, "    bearing_y: i16,\n");
    fprintf(out, "    data: []const u8,\n");
    fprintf(out, "};\n\n");
    fprintf(out, "pub const Font = struct {\n");
    fprintf(out, "    height: u16,\n");
    fprintf(out, "    ascent: u16,\n");
    fprintf(out, "    descent: u16,\n");
    fprintf(out, "    glyphs: std.AutoHashMap(u32, Glyph),\n");
    fprintf(out, "};\n\n");
}

// Helper to render a single glyph and write its data
void render_glyph(cairo_t *cr, cairo_font_face_t *face, double size, uint32_t codepoint, const char* font_name_suffix) {
    cairo_set_font_face(cr, face);
    cairo_set_font_size(cr, size);

    // Get extents
    cairo_text_extents_t extents;
    char utf8[5];
    int len = 0;
    if (codepoint < 0x80) {
        utf8[0] = (char)codepoint;
        utf8[1] = 0;
        len = 1;
    } else if (codepoint < 0x800) {
        utf8[0] = 0xC0 | (codepoint >> 6);
        utf8[1] = 0x80 | (codepoint & 0x3F);
        utf8[2] = 0;
        len = 2;
    } else if (codepoint < 0x10000) {
        utf8[0] = 0xE0 | (codepoint >> 12);
        utf8[1] = 0x80 | ((codepoint >> 6) & 0x3F);
        utf8[2] = 0x80 | (codepoint & 0x3F);
        utf8[3] = 0;
        len = 3;
    }
    
    cairo_text_extents(cr, utf8, &extents);

    int width = (int)extents.width + 2; // Add padding
    int height = (int)extents.height + 2;
    if (width <= 2) width = (int)extents.x_advance; // For space
    if (height <= 2) height = (int)size;

    // Create surface for glyph
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, width, height);
    cairo_t *g_cr = cairo_create(surface);
    
    // Clear
    cairo_set_source_rgba(g_cr, 0, 0, 0, 0);
    cairo_paint(g_cr);
    
    // Draw white text
    cairo_set_source_rgba(g_cr, 1, 1, 1, 1);
    cairo_set_font_face(g_cr, face);
    cairo_set_font_size(g_cr, size);
    
    // Position: -x_bearing to align left, -y_bearing to align top
    cairo_move_to(g_cr, -extents.x_bearing + 1, -extents.y_bearing + 1);
    cairo_show_text(g_cr, utf8);
    
    cairo_surface_flush(surface);
    unsigned char *data = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    
    // Output data array
    fprintf(out, "const glyph_%s_%d_%u = [_]u8{", font_name_suffix, (int)size, codepoint);
    
    // Pack bits (1 bit per pixel)
    // Threshold > 128
    int byte_val = 0;
    int bit_idx = 0;
    int count = 0;
    
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            unsigned char alpha = data[y * stride + x];
            if (alpha > 128) {
                byte_val |= (1 << (7 - bit_idx));
            }
            bit_idx++;
            if (bit_idx == 8) {
                fprintf(out, "0x%02X,", byte_val);
                byte_val = 0;
                bit_idx = 0;
                count++;
            }
        }
    }
    if (bit_idx > 0) {
        fprintf(out, "0x%02X,", byte_val);
        count++;
    }
    
    fprintf(out, "};\n");
    
    cairo_destroy(g_cr);
    cairo_surface_destroy(surface);
}

void generate_font(const char* font_path, const char* name, int* sizes, int sizes_count, uint32_t* codepoints, int cp_count) {
    FT_Library ft_library;
    FT_Init_FreeType(&ft_library);
    
    FT_Face ft_face;
    if (FT_New_Face(ft_library, font_path, 0, &ft_face)) {
        fprintf(stderr, "Failed to load font %s\n", font_path);
        return;
    }
    
    cairo_font_face_t *cairo_face = cairo_ft_font_face_create_for_ft_face(ft_face, 0);
    
    // Dummy surface for context
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 10, 10);
    cairo_t *cr = cairo_create(surface);
    
    for (int s = 0; s < sizes_count; s++) {
        int size = sizes[s];
        
        // Get font metrics
        cairo_set_font_face(cr, cairo_face);
        cairo_set_font_size(cr, size);
        cairo_font_extents_t font_extents;
        cairo_font_extents(cr, &font_extents);
        
        fprintf(out, "// Font: %s %d\n", name, size);
        
        // Generate glyphs
        for (int i = 0; i < cp_count; i++) {
            render_glyph(cr, cairo_face, size, codepoints[i], name);
        }
        
        // Generate map function
        fprintf(out, "pub fn init_%s_%d(allocator: std.mem.Allocator) !Font {\n", name, size);
        fprintf(out, "    var glyphs = std.AutoHashMap(u32, Glyph).init(allocator);\n");
        
        for (int i = 0; i < cp_count; i++) {
            uint32_t cp = codepoints[i];
            
            // Re-calculate dimensions for the struct
            cairo_text_extents_t extents;
            char utf8[5];
            if (cp < 0x80) { utf8[0] = (char)cp; utf8[1] = 0; }
            else if (cp < 0x800) { utf8[0] = 0xC0 | (cp >> 6); utf8[1] = 0x80 | (cp & 0x3F); utf8[2] = 0; }
            else { utf8[0] = 0xE0 | (cp >> 12); utf8[1] = 0x80 | ((cp >> 6) & 0x3F); utf8[2] = 0x80 | (cp & 0x3F); utf8[3] = 0; }
            
            cairo_text_extents(cr, utf8, &extents);
            int width = (int)extents.width + 2;
            int height = (int)extents.height + 2;
            if (width <= 2) width = (int)extents.x_advance;
            if (height <= 2) height = (int)size;
            
            fprintf(out, "    try glyphs.put(%u, Glyph{ .width = %d, .height = %d, .advance_x = %d, .bearing_x = %d, .bearing_y = %d, .data = &glyph_%s_%d_%u });\n",
                cp, width, height, (int)extents.x_advance, (int)(extents.x_bearing - 1), (int)(extents.y_bearing - 1), name, size, cp);
        }
        
        fprintf(out, "    return Font{ .height = %d, .ascent = %d, .descent = %d, .glyphs = glyphs };\n",
            (int)font_extents.height, (int)font_extents.ascent, (int)font_extents.descent);
        fprintf(out, "}\n\n");
    }
    
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    cairo_font_face_destroy(cairo_face);
    FT_Done_Face(ft_face);
    FT_Done_FreeType(ft_library);
}

int main() {
    out = fopen("src/font_data.zig", "w");
    if (!out) return 1;
    
    write_header();
    
    // Ubuntu Regular
    int ubuntu_sizes[] = {14, 20, 24, 26, 34};
    uint32_t ascii[95];
    for(int i=0; i<95; i++) ascii[i] = 32 + i;
    
    // Add degree symbol (0xB0)
    uint32_t ubuntu_cps[96];
    memcpy(ubuntu_cps, ascii, sizeof(ascii));
    ubuntu_cps[95] = 0xB0; // °
    
    generate_font("lib/fonts/Ubuntu-Regular.ttf", "ubuntu", ubuntu_sizes, 5, ubuntu_cps, 96);
    
    // Material Symbols
    int material_sizes[] = {14, 24, 50};
    uint32_t icons[] = {
        0xe30d, 0xe1ff, 0xe322, 0xf7a4, 0xf168, 0xe80d, 0xe923, 
        0xf090, 0xf09b, 0xe8e8, 0xe2bf, 0xf1ca, 0xe63e, 0xe1da, 0xeb2f
    };
    
    generate_font("lib/fonts/MaterialSymbolsRounded.ttf", "material", material_sizes, 3, icons, 15);
    
    fclose(out);
    return 0;
}
