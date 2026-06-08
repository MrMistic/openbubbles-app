package com.bluebubbles.messaging.services.system

import android.graphics.Bitmap

/**
 * Composites the alpha auxiliary track's luma channel as the alpha channel of
 * the color track's RGB pixels.
 *
 * Both tracks decode to ARGB_8888 bitmaps. The alpha track is monochrome HEVC,
 * so after YUV→RGB conversion its R, G, and B channels all carry the same
 * luma value. We sample the R channel and write it into the color frame's
 * alpha byte, producing straight (unpremultiplied) alpha that the existing
 * APNG encoder writes verbatim.
 *
 * Validates: Requirements 2.6, 7.3, 9.1, 9.2, 9.3.
 */
object AlphaCompositor {
    /**
     * Pixels with R, G, and B all below this value (out of 255) are treated
     * as black background and made fully transparent in the no-alpha-track
     * path. Set high enough to catch JPEG/HEVC compression artifacts around
     * the sticker silhouette but low enough to leave any meaningful dark
     * content (shadows, outlines) opaque.
     */
    private const val BLACK_THRESHOLD = 8

    /**
     * For each frame index `i` from 0 to `min(color.size, alpha.size) − 1`,
     * mutate `color[i]` so that its alpha channel equals `alpha[i].R` and its
     * RGB channels are unchanged. Recycles each `alpha[i]` immediately after
     * use to keep peak memory bounded.
     *
     * If `alpha` is empty, applies a chroma-key on near-black pixels so the
     * sticker shows correctly on any background (light mode, dark mode, custom
     * wallpapers, etc.) without compositing the original alpha matte. iOS
     * Live Stickers encode the foreground subject on a pure black canvas; any
     * pixel with R, G, B all below [BLACK_THRESHOLD] is treated as background
     * and made transparent. This is the "animate without alpha" path the user
     * opts into when the alpha auxiliary track can't be decoded on their
     * device.
     *
     * Returns the (mutated) color list, truncated if the two lists had
     * different lengths. Throws [IllegalArgumentException] if any color/alpha
     * frame pair has mismatched dimensions.
     */
    fun composite(color: MutableList<Bitmap>, alpha: MutableList<Bitmap>, blackThreshold: Int = BLACK_THRESHOLD): MutableList<Bitmap> {
        if (alpha.isEmpty()) {
            // Color-only path with chroma-key on near-black. Every pixel whose
            // R, G, and B are all below blackThreshold becomes transparent so
            // the sticker renders cleanly on any background. Anything with even
            // a hint of color stays opaque.
            for (c in color) {
                val w = c.width
                val h = c.height
                val px = IntArray(w * h)
                c.getPixels(px, 0, w, 0, 0, w, h)
                for (j in px.indices) {
                    val p = px[j]
                    val r = (p shr 16) and 0xFF
                    val g = (p shr 8) and 0xFF
                    val b = p and 0xFF
                    val alphaByte = if (r < blackThreshold &&
                                        g < blackThreshold &&
                                        b < blackThreshold) 0 else 0xFF
                    px[j] = (p and 0x00FFFFFF) or (alphaByte shl 24)
                }
                c.setHasAlpha(true)
                c.setPixels(px, 0, w, 0, 0, w, h)
            }
            return color
        }

        val n = minOf(color.size, alpha.size)
        for (i in 0 until n) {
            val c = color[i]
            val a = alpha[i]
            require(c.width == a.width && c.height == a.height) {
                "Frame $i color/alpha dim mismatch: ${c.width}x${c.height} vs ${a.width}x${a.height}"
            }
            val w = c.width
            val h = c.height
            val cPixels = IntArray(w * h)
            val aPixels = IntArray(w * h)
            c.getPixels(cPixels, 0, w, 0, 0, w, h)
            a.getPixels(aPixels, 0, w, 0, 0, w, h)

            for (j in cPixels.indices) {
                // Read alpha track's R channel (bits 16..23 of ARGB int).
                val alphaByte = (aPixels[j] shr 16) and 0xFF
                // Replace color frame's alpha channel (bits 24..31).
                cPixels[j] = (cPixels[j] and 0x00FFFFFF) or (alphaByte shl 24)
            }
            c.setHasAlpha(true)
            c.setPixels(cPixels, 0, w, 0, 0, w, h)

            // Free the alpha bitmap as we go.
            a.recycle()
        }
        // If the alpha list was longer than color, recycle its tail too.
        for (i in n until alpha.size) {
            if (!alpha[i].isRecycled) alpha[i].recycle()
        }
        // If color list was longer, drop the excess (they're orphaned without
        // an alpha frame).
        while (color.size > n) {
            val extra = color.removeAt(color.size - 1)
            if (!extra.isRecycled) extra.recycle()
        }
        return color
    }
}
