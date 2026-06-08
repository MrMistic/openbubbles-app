package com.bluebubbles.messaging.services.system

import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import java.io.File
import java.nio.ByteBuffer

/**
 * Drains both HEVC tracks of a brand-patched iOS Live Sticker file and turns
 * each track into a list of `ARGB_8888` [Bitmap]s.
 *
 * The output is two parallel lists (color frames and alpha frames) plus a list
 * of per-frame durations in milliseconds derived from the source `stts` deltas.
 * The alpha track frames are monochrome HEVC: the Y channel is the per-pixel
 * alpha mask. The caller composites them with [AlphaCompositor].
 *
 * Validates: Requirements 2.3, 2.4, 2.5, 2.7, 2.9, 7.2, 8.1, 8.2, 9.3.
 */
object MediaCodecRunner {
    private const val TAG = "HeicSeq.MCR"
    private const val DEQUEUE_TIMEOUT_US = 100_000L
    private const val MAX_FRAMES_PER_TRACK = 600

    /** The decoded output of both tracks, ready for compositing. */
    data class DualTrackFrames(
        val colorFrames: MutableList<Bitmap>,
        val alphaFrames: MutableList<Bitmap>,
        val perFrameDelaysMs: List<Int>
    )

    /**
     * Open [patchedFile] with two MediaExtractor instances, decode each HEVC
     * track to ARGB_8888 bitmaps, and return them along with per-frame delays.
     *
     * When [decodeAlpha] is false, only the color track is decoded and the
     * returned [DualTrackFrames.alphaFrames] is empty. The compositor will
     * then leave the color frames opaque (no transparency, black background
     * where alpha would have been).
     *
     * The caller MUST recycle the returned bitmaps after use; on exception this
     * function recycles everything it has allocated before re-throwing.
     */
    fun decodeTracks(
        patchedFile: File,
        hybrid: HybridFormatInfo,
        decodeAlpha: Boolean = true
    ): DualTrackFrames {
        val color = ArrayList<Bitmap>()
        val alpha = ArrayList<Bitmap>()
        try {
            decodeOneTrack(patchedFile, hybrid.colorTrackId, hybrid.colorNclx, color)
            if (decodeAlpha) {
                decodeOneTrack(patchedFile, hybrid.alphaTrackId, hybrid.alphaNclx, alpha,
                    useSoftwareDecoder = true)
            }

            val n = if (decodeAlpha) minOf(color.size, alpha.size) else color.size
            if (decodeAlpha && color.size != alpha.size) {
                Log.w(TAG, "color/alpha frame count mismatch: " +
                        "color=${color.size} alpha=${alpha.size}; truncating to $n")
            }

            val deltasMs = hybrid.colorSttsDeltas.take(n).map { delta ->
                ((delta.toDouble() * 1000.0) / hybrid.colorTimescale).toInt().coerceAtLeast(1)
            }
            // Pad with the last delta if our deltas list ran out (shouldn't normally happen).
            val padded = if (deltasMs.size < n) {
                deltasMs + List(n - deltasMs.size) { deltasMs.lastOrNull() ?: 67 }
            } else deltasMs

            return DualTrackFrames(color, alpha, padded)
        } catch (e: Throwable) {
            color.forEach { if (!it.isRecycled) it.recycle() }
            alpha.forEach { if (!it.isRecycled) it.recycle() }
            throw e
        }
    }

    /** Drains a single HEVC track into [out] as ARGB_8888 bitmaps. */
    private fun decodeOneTrack(
        file: File,
        trackId: Int,
        nclx: NclxColor?,
        out: MutableList<Bitmap>,
        useSoftwareDecoder: Boolean = false
    ) {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            Log.i(TAG, "decodeOneTrack: trackId=$trackId opening ${file.absolutePath} (${file.length()} bytes)")
            extractor.setDataSource(file.absolutePath)
            Log.i(TAG, "decodeOneTrack: trackId=$trackId extractor opened, trackCount=${extractor.trackCount}")
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME)
                val tid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                    f.containsKey(MediaFormat.KEY_TRACK_ID)) f.getInteger(MediaFormat.KEY_TRACK_ID) else -1
                val w = if (f.containsKey(MediaFormat.KEY_WIDTH)) f.getInteger(MediaFormat.KEY_WIDTH) else -1
                val h = if (f.containsKey(MediaFormat.KEY_HEIGHT)) f.getInteger(MediaFormat.KEY_HEIGHT) else -1
                val csdKeys = listOf("csd-0", "csd-1", "csd-2").filter { f.containsKey(it) }
                Log.i(TAG, "decodeOneTrack:   ext-track $i: mime=$mime tid=$tid ${w}x$h csd=$csdKeys")
            }
            val mediaTrackIndex = findMediaExtractorTrack(extractor, trackId)
                ?: throw IllegalStateException(
                    "MediaExtractor has no track with mp4 id $trackId; " +
                    "extractor sees ${extractor.trackCount} tracks"
                )
            Log.i(TAG, "decodeOneTrack: trackId=$trackId mapped to extractor index $mediaTrackIndex")
            extractor.selectTrack(mediaTrackIndex)
            val format = extractor.getTrackFormat(mediaTrackIndex)
            applyColorSpace(format, nclx)

            val mime = format.getString(MediaFormat.KEY_MIME)
                ?: throw IllegalStateException("Track $mediaTrackIndex has no MIME type")
            Log.i(TAG, "decodeOneTrack: trackId=$trackId track format keys=${formatKeys(format)}")
            Log.i(TAG, "decodeOneTrack: trackId=$trackId creating decoder for $mime")
            codec = findDecoder(mime, preferSoftware = useSoftwareDecoder)
            Log.i(TAG, "decodeOneTrack: trackId=$trackId picked decoder ${codec.name}")
            try {
                codec.configure(format, null, null, 0)
            } catch (e: Throwable) {
                Log.w(TAG, "decodeOneTrack: trackId=$trackId codec.configure failed: ${e.javaClass.simpleName}: ${e.message}")
                throw e
            }
            codec.start()
            Log.i(TAG, "decodeOneTrack: trackId=$trackId codec started, beginning drain")

            drainSamples(extractor, codec, nclx, out)
            Log.i(TAG, "decodeOneTrack: trackId=$trackId drain complete, ${out.size} frames")
        } finally {
            try { codec?.stop() } catch (e: Throwable) {
                Log.w(TAG, "decodeOneTrack: trackId=$trackId codec.stop() threw: ${e.javaClass.simpleName}: ${e.message}")
            }
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    /**
     * MediaExtractor exposes tracks by index, but ISO BMFF identifies them by
     * track_id from `tkhd`. The two usually agree (track 1 = index 0, track 2
     * = index 1) but the spec doesn't require it. Since ICS, MediaFormat
     * exposes `KEY_TRACK_ID` we can match against — fall back to "index ==
     * track_id − 1" when the key is absent.
     */
    private fun findMediaExtractorTrack(extractor: MediaExtractor, trackId: Int): Int? {
        for (i in 0 until extractor.trackCount) {
            val fmt = extractor.getTrackFormat(i)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                fmt.containsKey(MediaFormat.KEY_TRACK_ID)) {
                if (fmt.getInteger(MediaFormat.KEY_TRACK_ID) == trackId) return i
            }
        }
        // Fallback: convention.
        val byConvention = trackId - 1
        return if (byConvention in 0 until extractor.trackCount) byConvention else null
    }

    /**
     * Dump the keys and values of a [MediaFormat] for diagnostic logging.
     * MediaFormat doesn't expose its internal map, so we probe the common
     * HEVC keys explicitly.
     */
    private fun formatKeys(format: MediaFormat): String {
        val keys = listOf(
            MediaFormat.KEY_MIME,
            MediaFormat.KEY_WIDTH,
            MediaFormat.KEY_HEIGHT,
            MediaFormat.KEY_FRAME_RATE,
            MediaFormat.KEY_DURATION,
            MediaFormat.KEY_PROFILE,
            MediaFormat.KEY_LEVEL,
            MediaFormat.KEY_BIT_RATE,
            MediaFormat.KEY_COLOR_FORMAT,
            MediaFormat.KEY_COLOR_RANGE,
            MediaFormat.KEY_COLOR_STANDARD,
            MediaFormat.KEY_COLOR_TRANSFER,
            MediaFormat.KEY_TRACK_ID,
            "csd-0",
            "csd-1",
            "csd-2",
            "max-input-size"
        )
        val sb = StringBuilder()
        for (k in keys) {
            if (!format.containsKey(k)) continue
            val v: Any? = try {
                when (k) {
                    MediaFormat.KEY_MIME -> format.getString(k)
                    "csd-0", "csd-1", "csd-2" -> {
                        val bb = format.getByteBuffer(k)
                        if (bb == null) "null" else "ByteBuffer(${bb.remaining()}B)"
                    }
                    MediaFormat.KEY_DURATION -> format.getLong(k)
                    else -> format.getInteger(k)
                }
            } catch (_: Throwable) {
                "?"
            }
            if (sb.isNotEmpty()) sb.append(", ")
            sb.append(k).append("=").append(v)
        }
        return sb.toString()
    }

    /**
     * Find a decoder for [mime], preferring a software codec when
     * [preferSoftware] is true. The alpha auxiliary track in iOS Live Stickers
     * uses monochrome HEVC which many hardware decoders reject. Using the
     * platform's software HEVC decoder (`c2.android.hevc.decoder`) avoids
     * this limitation.
     *
     * Falls back to [MediaCodec.createDecoderByType] if no software decoder
     * is found (shouldn't happen on API 28+ but defensive).
     */
    private fun findDecoder(mime: String, preferSoftware: Boolean): MediaCodec {
        if (!preferSoftware) {
            return MediaCodec.createDecoderByType(mime)
        }
        val codecList = android.media.MediaCodecList(android.media.MediaCodecList.ALL_CODECS)
        for (info in codecList.codecInfos) {
            if (info.isEncoder) continue
            if (!info.supportedTypes.any { it.equals(mime, ignoreCase = true) }) continue
            if (info.isSoftwareOnly ||
                info.name.startsWith("c2.android.") ||
                info.name.startsWith("OMX.google.")) {
                Log.i(TAG, "findDecoder: using software decoder ${info.name} for $mime")
                return MediaCodec.createByCodecName(info.name)
            }
        }
        Log.w(TAG, "findDecoder: no software decoder found for $mime, falling back to default")
        return MediaCodec.createDecoderByType(mime)
    }

    /**
     * Set MediaCodec input format color-space keys to match the source.
     *
     * Note: HEVC decoders typically return frames as YUV420 planar regardless
     * of these keys — the keys are advisory, not output-format selectors. The
     * actual color correctness comes from the per-pixel YUV→ARGB conversion
     * in [imageToBitmap], which reads `nclx` directly via [pickMatrix] and
     * [yuvToArgb]. Setting these keys on the input format is still useful: it
     * prevents the codec from picking a wrong default if the upstream HEVC
     * sequence parameters were ambiguous, and it lets future versions of the
     * decoder hint at the output range it should produce.
     *
     * Validates: Requirements 8.1, 8.2.
     */
    private fun applyColorSpace(format: MediaFormat, nclx: NclxColor?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        val mc = nclx?.matrixCoefficients ?: 1
        val tc = nclx?.transferCharacteristics ?: 1
        val full = nclx?.fullRangeFlag ?: true

        val standard = when (mc) {
            1 -> MediaFormat.COLOR_STANDARD_BT709
            6 -> MediaFormat.COLOR_STANDARD_BT601_NTSC
            9 -> MediaFormat.COLOR_STANDARD_BT2020
            else -> MediaFormat.COLOR_STANDARD_BT709
        }
        val transfer = when (tc) {
            1, 6, 14, 15 -> MediaFormat.COLOR_TRANSFER_SDR_VIDEO
            13 -> MediaFormat.COLOR_TRANSFER_SDR_VIDEO  // closest to sRGB
            16 -> MediaFormat.COLOR_TRANSFER_ST2084
            else -> MediaFormat.COLOR_TRANSFER_SDR_VIDEO
        }
        val range = if (full) MediaFormat.COLOR_RANGE_FULL else MediaFormat.COLOR_RANGE_LIMITED

        format.setInteger(MediaFormat.KEY_COLOR_STANDARD, standard)
        format.setInteger(MediaFormat.KEY_COLOR_TRANSFER, transfer)
        format.setInteger(MediaFormat.KEY_COLOR_RANGE, range)
    }

    private fun drainSamples(
        extractor: MediaExtractor,
        codec: MediaCodec,
        nclx: NclxColor?,
        out: MutableList<Bitmap>
    ) {
        val bufferInfo = MediaCodec.BufferInfo()
        var sawInputEos = false
        var sawOutputEos = false
        var inputCount = 0
        var outputCount = 0
        var formatChanged = 0

        while (!sawOutputEos && out.size < MAX_FRAMES_PER_TRACK) {
            // Feed samples into the decoder.
            if (!sawInputEos) {
                val inIndex = try {
                    codec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                } catch (e: Throwable) {
                    Log.w(TAG, "drainSamples: dequeueInputBuffer threw at input #$inputCount output #$outputCount: ${e.javaClass.simpleName}: ${e.message}")
                    throw e
                }
                if (inIndex >= 0) {
                    val inBuf: ByteBuffer = codec.getInputBuffer(inIndex)
                        ?: throw IllegalStateException("Null input buffer at index $inIndex")
                    val sampleSize = extractor.readSampleData(inBuf, 0)
                    if (sampleSize < 0) {
                        codec.queueInputBuffer(inIndex, 0, 0, 0,
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        sawInputEos = true
                        Log.i(TAG, "drainSamples: queued EOS after $inputCount samples")
                    } else {
                        codec.queueInputBuffer(inIndex, 0, sampleSize,
                            extractor.sampleTime, 0)
                        extractor.advance()
                        inputCount++
                    }
                }
            }

            // Drain decoded frames.
            val outIndex = try {
                codec.dequeueOutputBuffer(bufferInfo, DEQUEUE_TIMEOUT_US)
            } catch (e: Throwable) {
                Log.w(TAG, "drainSamples: dequeueOutputBuffer threw at input #$inputCount output #$outputCount eos=$sawInputEos: ${e.javaClass.simpleName}: ${e.message}")
                throw e
            }
            when {
                outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    // No frame ready; loop and try again.
                }
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    formatChanged++
                    val newFmt = codec.outputFormat
                    val outFmt = newFmt.getInteger(MediaFormat.KEY_COLOR_FORMAT, -1)
                    val w = newFmt.getInteger(MediaFormat.KEY_WIDTH, -1)
                    val h = newFmt.getInteger(MediaFormat.KEY_HEIGHT, -1)
                    Log.i(TAG, "drainSamples: output format changed to ${w}x$h colorFormat=0x${outFmt.toString(16)}")
                }
                outIndex >= 0 -> {
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        sawOutputEos = true
                    }
                    if (bufferInfo.size > 0) {
                        val image: Image? = codec.getOutputImage(outIndex)
                        if (image != null) {
                            try {
                                out.add(imageToBitmap(image, nclx))
                                outputCount++
                            } finally {
                                image.close()
                            }
                        } else {
                            Log.w(TAG, "drainSamples: getOutputImage returned null for index $outIndex")
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                }
                else -> {
                    Log.w(TAG, "drainSamples: unexpected dequeueOutputBuffer return: $outIndex")
                }
            }
        }
        Log.i(TAG, "drainSamples: exit input=$inputCount output=$outputCount formatChanges=$formatChanged eos=$sawOutputEos")
    }

    /**
     * Convert a YUV_420_888 [Image] to an `ARGB_8888` [Bitmap]. The conversion
     * matrix is selected from [nclx]; defaults to BT.709 full range.
     */
    private fun imageToBitmap(image: Image, nclx: NclxColor?): Bitmap {
        require(image.format == ImageFormat.YUV_420_888) {
            "Expected YUV_420_888 output but got format ${image.format}"
        }
        val w = image.width
        val h = image.height
        val planes = image.planes
        val yPlane = planes[0]
        val uPlane = planes[1]
        val vPlane = planes[2]

        val yBuf = yPlane.buffer
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer
        val yRowStride = yPlane.rowStride
        val uRowStride = uPlane.rowStride
        val vRowStride = vPlane.rowStride
        val uPixelStride = uPlane.pixelStride
        val vPixelStride = vPlane.pixelStride

        val pixels = IntArray(w * h)
        val matrix = pickMatrix(nclx?.matrixCoefficients ?: 1)
        val fullRange = nclx?.fullRangeFlag ?: true

        for (y in 0 until h) {
            val uvRow = y shr 1
            for (x in 0 until w) {
                val uvCol = x shr 1
                val yByte = yBuf.get(y * yRowStride + x).toInt() and 0xFF
                val uByte = uBuf.get(uvRow * uRowStride + uvCol * uPixelStride).toInt() and 0xFF
                val vByte = vBuf.get(uvRow * vRowStride + uvCol * vPixelStride).toInt() and 0xFF

                val argb = yuvToArgb(yByte, uByte, vByte, matrix, fullRange)
                pixels[y * w + x] = argb
            }
        }

        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        out.setHasAlpha(true)
        out.setPixels(pixels, 0, w, 0, 0, w, h)
        return out
    }

    /** Coefficient triple `(Kr, Kg, Kb)` for the picked YUV matrix. */
    private data class YuvMatrix(val kr: Double, val kg: Double, val kb: Double)

    private fun pickMatrix(matrixCoefficients: Int): YuvMatrix = when (matrixCoefficients) {
        1 -> YuvMatrix(0.2126, 0.7152, 0.0722)   // BT.709
        6 -> YuvMatrix(0.299, 0.587, 0.114)      // BT.601 NTSC
        9 -> YuvMatrix(0.2627, 0.6780, 0.0593)   // BT.2020
        else -> YuvMatrix(0.2126, 0.7152, 0.0722) // default to BT.709
    }

    /**
     * Convert a single `(Y, U, V)` sample to packed `ARGB_8888` (alpha=0xFF).
     *
     * Implements the canonical inverse colour-conversion matrix:
     *   R = Y + (1 − Kr) * Cr
     *   B = Y + (1 − Kb) * Cb
     *   G = Y − (Kr * (1 − Kr) / Kg) * Cr − (Kb * (1 − Kb) / Kg) * Cb
     * where Cr = V − 128 and Cb = U − 128 (both centered at 128).
     *
     * In limited range, Y is offset by 16 and scaled to [16, 235] = 219 levels;
     * U and V live in [16, 240] = 224 levels.
     */
    private fun yuvToArgb(y: Int, u: Int, v: Int, m: YuvMatrix, fullRange: Boolean): Int {
        val yf: Double; val cb: Double; val cr: Double
        if (fullRange) {
            yf = y.toDouble()
            cb = (u - 128).toDouble()
            cr = (v - 128).toDouble()
        } else {
            yf = ((y - 16).coerceAtLeast(0) * 255.0 / 219.0)
            cb = ((u - 128) * 255.0 / 224.0)
            cr = ((v - 128) * 255.0 / 224.0)
        }
        val r = yf + (1 - m.kr) / 0.5 * cr
        val b = yf + (1 - m.kb) / 0.5 * cb
        val g = yf - (m.kr * (1 - m.kr) / m.kg) / 0.5 * cr -
                    (m.kb * (1 - m.kb) / m.kg) / 0.5 * cb

        val rb = clamp255(r)
        val gb = clamp255(g)
        val bb = clamp255(b)
        return (0xFF shl 24) or (rb shl 16) or (gb shl 8) or bb
    }

    private fun clamp255(v: Double): Int {
        val i = (v + 0.5).toInt()
        return if (i < 0) 0 else if (i > 255) 255 else i
    }
}
