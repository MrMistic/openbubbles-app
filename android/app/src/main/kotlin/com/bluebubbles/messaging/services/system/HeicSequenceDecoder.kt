package com.bluebubbles.messaging.services.system

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.drawable.AnimatedImageDrawable
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.util.zip.CRC32
import java.util.zip.Deflater

/**
 * Method channel handler that turns an iOS Live Sticker `.heics` file into an
 * animated APNG byte array.
 *
 * iOS Live Stickers are an ISO BMFF hybrid: the `meta` box describes only two
 * still items (a primary HEVC color image and an alpha auxiliary HEVC image),
 * while the actual animation lives in the file's `moov` box as two parallel
 * HEVC tracks. Android's `MediaMetadataRetriever` and `ImageDecoder` only
 * inspect `meta` and reject these files outright. The pipeline below mirrors
 * what iOS itself does to render Live Stickers:
 *
 *  1. [BoxParser] walks the box tree and detects whether the file is a Live
 *     Sticker hybrid format.
 *  2. [BrandPatcher] copies the source to a temp file and rewrites the major
 *     brand from `msf1` to `iso8` so MediaExtractor accepts it.
 *  3. [MediaCodecRunner] decodes both HEVC tracks into ARGB_8888 bitmaps.
 *  4. [AlphaCompositor] writes the alpha-track luma into the color-track
 *     alpha channel.
 *  5. [encodeApng] serializes the composited frames as an animated APNG with
 *     per-frame durations from the source `stts` deltas.
 *
 * If hybrid detection fails (or any later stage fails), the decoder falls
 * back to the legacy `ImageDecoder.decodeDrawable` path, which works on
 * simpler synthetic HEIF image-sequences. If that also fails, the Dart
 * caller's `convertHeicToPng` chain handles HeifCoder + FlutterImageCompress.
 */
class HeicSequenceDecoder : MethodCallHandlerImpl() {
    companion object {
        const val tag = "decode-heic-sequence"
        private const val LOG_TAG = "HeicSeq"
        private const val MAX_DIMENSION = 320 // legacy fallback only
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val filePath: String = call.argument("file") ?: run {
            result.error("FILE_NOT_FOUND", "No file argument provided", null)
            return
        }
        val srcFile = File(filePath)
        if (!srcFile.exists() || !srcFile.canRead()) {
            result.error("FILE_NOT_FOUND", filePath, null)
            return
        }
        // Caller can pass animateNoAlpha=true to force the color-only animated
        // path (no transparency). Default false → static still with alpha.
        val animateNoAlpha: Boolean = call.argument("animateNoAlpha") ?: false
        val blackThreshold: Int = call.argument("blackThreshold") ?: 8

        val worker = HandlerThread("heic-seq-worker").apply { start() }
        Handler(worker.looper).post {
            try {
                val bytes = decodePipeline(srcFile, context, animateNoAlpha, blackThreshold)
                Handler(context.mainLooper).post { result.success(bytes) }
            } catch (e: BrandPatchException) {
                Log.w(LOG_TAG, "BRAND_PATCH_FAILED: ${e.message}")
                Handler(context.mainLooper).post {
                    result.error("BRAND_PATCH_FAILED", e.message ?: "Brand patch failed", null)
                }
            } catch (e: UnsupportedFormatException) {
                Log.w(LOG_TAG, "UNSUPPORTED_FORMAT: ${e.message}")
                Handler(context.mainLooper).post {
                    result.error("UNSUPPORTED_FORMAT", e.message ?: "Unsupported format", null)
                }
            } catch (e: Exception) {
                Log.w(LOG_TAG, "DECODE_FAILED: ${e.javaClass.simpleName}: ${e.message}")
                Handler(context.mainLooper).post {
                    result.error("DECODE_FAILED", "${e.javaClass.simpleName}: ${e.message}", null)
                }
            } finally {
                worker.quitSafely()
            }
        }
    }

    /** Top-level orchestrator: detect, patch, decode, composite, encode. */
    private fun decodePipeline(srcFile: File, context: Context, animateNoAlpha: Boolean, blackThreshold: Int): ByteArray {
        // 1. Parse the box tree (cheap; bounded by box count, not file size).
        val tree = BoxParser.parse(srcFile)

        // 2. Try the hybrid Live Sticker path.
        val hybrid = BoxParser.detectHybrid(tree, srcFile)
        if (hybrid != null) {
            return decodeHybrid(srcFile, tree, hybrid, context, animateNoAlpha, blackThreshold)
        }

        // 3. Hybrid not detected — try the legacy ImageDecoder path.
        Log.i(LOG_TAG, "File is not a Live Sticker hybrid format; trying legacy ImageDecoder")
        val legacy = legacyImageDecoderFallback(srcFile)
        if (legacy != null) return legacy

        throw UnsupportedFormatException(
            "File is not a Live Sticker hybrid format and ImageDecoder fallback failed"
        )
    }

    /** The full hybrid Live Sticker decode + composite + encode pipeline. */
    private fun decodeHybrid(
        srcFile: File,
        tree: BoxTree,
        hybrid: HybridFormatInfo,
        context: Context,
        animateNoAlpha: Boolean,
        blackThreshold: Int
    ): ByteArray {
        Log.i(LOG_TAG, "Live Sticker hybrid format detected: " +
                "color=${hybrid.colorSttsDeltas.size}f alpha=${hybrid.alphaSttsDeltas.size}f " +
                "ts=${hybrid.colorTimescale} colr=${hybrid.colorNclx} animateNoAlpha=$animateNoAlpha")

        // Brand patch into a temp file. May throw BrandPatchException.
        val patched = BrandPatcher.patch(srcFile, context.cacheDir, tree.ftypOffset)
        try {
            val frames = MediaCodecRunner.decodeTracks(patched, hybrid, decodeAlpha = !animateNoAlpha)
            try {
                if (frames.colorFrames.isEmpty()) {
                    throw IllegalStateException("Hybrid decode produced zero color frames")
                }
                Log.i(LOG_TAG, "Decoded ${frames.colorFrames.size} color frames, " +
                        "${frames.alphaFrames.size} alpha frames")

                // Composite alpha into color. AlphaCompositor recycles alpha
                // bitmaps as it goes, dropping our peak memory back down.
                // When animateNoAlpha is true, alphaFrames is empty and the
                // compositor produces opaque frames.
                val composited = AlphaCompositor.composite(frames.colorFrames, frames.alphaFrames, blackThreshold)
                if (composited.isEmpty()) {
                    throw IllegalStateException("Compositor produced zero frames")
                }

                val delays = frames.perFrameDelaysMs.take(composited.size)
                return encodeApng(composited, delays)
            } finally {
                // Defensive: ensure any leftover bitmaps are released.
                frames.colorFrames.forEach { if (!it.isRecycled) it.recycle() }
                frames.alphaFrames.forEach { if (!it.isRecycled) it.recycle() }
            }
        } finally {
            try { patched.delete() } catch (_: Throwable) {}
        }
    }

    /**
     * The previous decoder. Kept for backwards compatibility with simpler
     * synthetic HEIF image-sequences that do not have a moov-based animation.
     * Returns null on any failure so the caller can escalate to
     * `UNSUPPORTED_FORMAT`.
     */
    private fun legacyImageDecoderFallback(file: File): ByteArray? = try {
        val source = ImageDecoder.createSource(file)
        val drawable = ImageDecoder.decodeDrawable(source) { decoder, _, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }

        if (drawable !is AnimatedImageDrawable) {
            // Single-frame source: encode a 1-frame APNG.
            val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { d, _, _ ->
                d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
            try {
                val scaled = scaleBitmap(bitmap)
                try {
                    encodeApng(listOf(scaled), listOf(67))
                } finally {
                    if (scaled !== bitmap) scaled.recycle()
                }
            } finally {
                bitmap.recycle()
            }
        } else {
            captureAnimatedDrawable(drawable)
        }
    } catch (e: Throwable) {
        Log.w(LOG_TAG, "Legacy ImageDecoder fallback failed: ${e.javaClass.simpleName}: ${e.message}")
        null
    }

    /** Frame-capture loop for `AnimatedImageDrawable`, used by the legacy path. */
    private fun captureAnimatedDrawable(drawable: AnimatedImageDrawable): ByteArray? {
        val srcWidth = drawable.intrinsicWidth
        val srcHeight = drawable.intrinsicHeight
        drawable.setBounds(0, 0, srcWidth, srcHeight)

        val scale = MAX_DIMENSION.toFloat() / maxOf(srcWidth, srcHeight)
        val outWidth = (srcWidth * scale).toInt().coerceAtLeast(1)
        val outHeight = (srcHeight * scale).toInt().coerceAtLeast(1)

        val animThread = HandlerThread("heic-anim")
        animThread.start()
        val animHandler = Handler(animThread.looper)
        val frames = mutableListOf<Bitmap>()

        try {
            drawable.repeatCount = 0
            drawable.callback = object : android.graphics.drawable.Drawable.Callback {
                override fun invalidateDrawable(who: android.graphics.drawable.Drawable) {}
                override fun scheduleDrawable(
                    who: android.graphics.drawable.Drawable, what: Runnable, `when`: Long
                ) {
                    animHandler.postAtTime(what, `when`)
                }
                override fun unscheduleDrawable(
                    who: android.graphics.drawable.Drawable, what: Runnable
                ) {
                    animHandler.removeCallbacks(what)
                }
            }

            val srcBitmap = Bitmap.createBitmap(srcWidth, srcHeight, Bitmap.Config.ARGB_8888)
            srcBitmap.setHasAlpha(true)
            val srcCanvas = Canvas(srcBitmap)
            drawable.draw(srcCanvas)
            frames.add(scaleBitmapTo(srcBitmap, outWidth, outHeight))
            srcBitmap.recycle()

            drawable.start()
            val maxFrames = 120
            val pollIntervalMs = 10L
            var lastHash = frameHash(frames[0])
            var sameCount = 0
            var totalPolls = 0
            val maxPolls = 5000

            while (frames.size < maxFrames && totalPolls < maxPolls) {
                Thread.sleep(pollIntervalMs)
                totalPolls++
                val captureBitmap = Bitmap.createBitmap(srcWidth, srcHeight, Bitmap.Config.ARGB_8888)
                captureBitmap.setHasAlpha(true)
                val captureCanvas = Canvas(captureBitmap)
                drawable.draw(captureCanvas)
                val hash = frameHash(captureBitmap, outWidth, outHeight)
                if (hash == lastHash) {
                    captureBitmap.recycle()
                    sameCount++
                    if (sameCount >= 15) break
                    continue
                }
                sameCount = 0
                lastHash = hash
                frames.add(scaleBitmapTo(captureBitmap, outWidth, outHeight))
                captureBitmap.recycle()
            }
            drawable.stop()
            if (frames.size < 2) return null
            val captureDurationMs = totalPolls * pollIntervalMs
            val actualFps = (frames.size * 1000.0 / captureDurationMs).toInt().coerceIn(10, 60)
            val perFrameMs = (1000.0 / actualFps).toInt().coerceAtLeast(1)
            return encodeApng(frames, List(frames.size) { perFrameMs })
        } finally {
            for (b in frames) if (!b.isRecycled) b.recycle()
            animThread.quitSafely()
        }
    }

    private fun scaleBitmap(bitmap: Bitmap): Bitmap {
        val scale = MAX_DIMENSION.toFloat() / maxOf(bitmap.width, bitmap.height)
        if (scale >= 1f) return bitmap
        val outWidth = (bitmap.width * scale).toInt().coerceAtLeast(1)
        val outHeight = (bitmap.height * scale).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(bitmap, outWidth, outHeight, true)
    }

    private fun scaleBitmapTo(bitmap: Bitmap, width: Int, height: Int): Bitmap {
        val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        output.setHasAlpha(true)
        val canvas = Canvas(output)
        val srcRect = android.graphics.Rect(0, 0, bitmap.width, bitmap.height)
        val dstRect = android.graphics.Rect(0, 0, width, height)
        val paint = android.graphics.Paint(android.graphics.Paint.FILTER_BITMAP_FLAG)
        canvas.drawBitmap(bitmap, srcRect, dstRect, paint)
        return output
    }

    private fun frameHash(bitmap: Bitmap): Long {
        val w = bitmap.width
        val h = bitmap.height
        var hash = 17L
        hash = hash * 31 + bitmap.getPixel(0, 0).toLong()
        hash = hash * 31 + bitmap.getPixel(w / 2, h / 2).toLong()
        hash = hash * 31 + bitmap.getPixel(w - 1, h - 1).toLong()
        hash = hash * 31 + bitmap.getPixel(w / 4, h / 4).toLong()
        hash = hash * 31 + bitmap.getPixel(3 * w / 4, 3 * h / 4).toLong()
        return hash
    }

    private fun frameHash(bitmap: Bitmap, scaledW: Int, scaledH: Int): Long {
        val w = bitmap.width
        val h = bitmap.height
        var hash = 17L
        hash = hash * 31 + bitmap.getPixel(0, 0).toLong()
        hash = hash * 31 + bitmap.getPixel(w / 2, h / 2).toLong()
        hash = hash * 31 + bitmap.getPixel(w - 1, h - 1).toLong()
        hash = hash * 31 + bitmap.getPixel(w / 4, h / 4).toLong()
        hash = hash * 31 + bitmap.getPixel(3 * w / 4, 3 * h / 4).toLong()
        return hash
    }

    // -- APNG encoder -------------------------------------------------------

    /**
     * Serialize [frames] as an animated APNG with the given per-frame delays
     * in milliseconds. The output is RGBA (color type 6) with straight,
     * unpremultiplied alpha so the Flutter image codec plays it directly.
     *
     * Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5.
     */
    private fun encodeApng(frames: List<Bitmap>, perFrameDelaysMs: List<Int>): ByteArray {
        require(frames.isNotEmpty()) { "encodeApng requires at least one frame" }
        require(perFrameDelaysMs.size == frames.size) {
            "encodeApng: delay count (${perFrameDelaysMs.size}) does not match frame count (${frames.size})"
        }
        val width = frames[0].width
        val height = frames[0].height
        val out = ByteArrayOutputStream()

        // PNG signature
        out.write(byteArrayOf(
            0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
        ))

        // IHDR chunk
        val ihdrData = ByteBuffer.allocate(13)
        ihdrData.putInt(width)
        ihdrData.putInt(height)
        ihdrData.put(8) // bit depth
        ihdrData.put(6) // color type: RGBA
        ihdrData.put(0) // compression method
        ihdrData.put(0) // filter method
        ihdrData.put(0) // interlace method
        writeChunk(out, "IHDR", ihdrData.array())

        // acTL chunk (animation control)
        val actlData = ByteBuffer.allocate(8)
        actlData.putInt(frames.size)  // num_frames
        actlData.putInt(0)            // num_plays = 0 (infinite loop)
        writeChunk(out, "acTL", actlData.array())

        var sequenceNumber = 0
        for (i in frames.indices) {
            val bitmap = frames[i]
            val delayMs = perFrameDelaysMs[i].coerceAtLeast(1)

            // fcTL chunk (frame control)
            val fctlData = ByteBuffer.allocate(26)
            fctlData.putInt(sequenceNumber++)        // sequence_number
            fctlData.putInt(width)                   // width
            fctlData.putInt(height)                  // height
            fctlData.putInt(0)                       // x_offset
            fctlData.putInt(0)                       // y_offset
            fctlData.putShort(delayMs.toShort())     // delay_num
            fctlData.putShort(1000.toShort())        // delay_den (always milliseconds)
            fctlData.put(0)                          // dispose_op: NONE
            fctlData.put(0)                          // blend_op: SOURCE
            writeChunk(out, "fcTL", fctlData.array())

            val compressedData = compressFrame(bitmap)
            if (i == 0) {
                writeChunk(out, "IDAT", compressedData)
            } else {
                val fdatData = ByteBuffer.allocate(4 + compressedData.size)
                fdatData.putInt(sequenceNumber++)    // sequence_number
                fdatData.put(compressedData)
                writeChunk(out, "fdAT", fdatData.array())
            }
        }

        writeChunk(out, "IEND", byteArrayOf())
        return out.toByteArray()
    }

    private fun compressFrame(bitmap: Bitmap): ByteArray {
        val width = bitmap.width
        val height = bitmap.height

        val rowSize = 1 + width * 4
        val rawData = ByteArray(rowSize * height)
        val pixels = IntArray(width)

        for (y in 0 until height) {
            val rowOffset = y * rowSize
            rawData[rowOffset] = 0 // filter byte: None

            bitmap.getPixels(pixels, 0, width, 0, y, width, 1)
            for (x in 0 until width) {
                val pixel = pixels[x]
                val pixelOffset = rowOffset + 1 + x * 4
                rawData[pixelOffset] = ((pixel shr 16) and 0xFF).toByte()      // R
                rawData[pixelOffset + 1] = ((pixel shr 8) and 0xFF).toByte()   // G
                rawData[pixelOffset + 2] = (pixel and 0xFF).toByte()           // B
                rawData[pixelOffset + 3] = ((pixel shr 24) and 0xFF).toByte()  // A
            }
        }

        val deflater = Deflater(Deflater.BEST_SPEED)
        deflater.setInput(rawData)
        deflater.finish()
        val compressedOut = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (!deflater.finished()) {
            val count = deflater.deflate(buffer)
            compressedOut.write(buffer, 0, count)
        }
        deflater.end()
        return compressedOut.toByteArray()
    }

    private fun writeChunk(out: ByteArrayOutputStream, type: String, data: ByteArray) {
        val typeBytes = type.toByteArray(Charsets.US_ASCII)
        val length = ByteBuffer.allocate(4)
        length.putInt(data.size)
        out.write(length.array())
        out.write(typeBytes)
        out.write(data)
        val crc = CRC32()
        crc.update(typeBytes)
        crc.update(data)
        val crcValue = ByteBuffer.allocate(4)
        crcValue.putInt(crc.value.toInt())
        out.write(crcValue.array())
    }
}

/**
 * Internal sentinel raised by [HeicSequenceDecoder] when neither the hybrid
 * nor the legacy decode path can interpret the file. Surfaces as the
 * `UNSUPPORTED_FORMAT` MethodChannel error code.
 */
private class UnsupportedFormatException(message: String) : Exception(message)
