package com.bluebubbles.messaging.services.system

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile

/**
 * Thrown when [BrandPatcher.patch] cannot create a brand-patched temp copy of
 * the source file. Surfaces as the `BRAND_PATCH_FAILED` MethodChannel error
 * code so the user-facing fix ("free up disk") is distinguishable from
 * generic decoder failures.
 *
 * Validates: Requirements 2.10, 6.7.
 */
class BrandPatchException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Rewrites the `ftyp` major brand of an iOS Live Sticker file from `msf1` to
 * `iso8` in a temporary copy.
 *
 * Live Stickers always include `iso8` in their compatible_brands list, so this
 * is a semantic no-op — it only changes the four bytes that Android's MP4
 * sniffer rejects on. After the patch, MediaExtractor accepts the file and
 * the rest of the moov-based decode pipeline can proceed.
 *
 * Validates: Requirements 2.2, 2.10, 7.4.
 */
object BrandPatcher {
    /**
     * Copies [src] into [cacheDir] with a unique nanotime-suffixed name and
     * rewrites bytes `[ftypOffset+8 .. ftypOffset+12]` (the major brand) with
     * the ASCII bytes `iso8`. The caller is responsible for deleting the
     * returned file after the decode completes.
     *
     * Throws [BrandPatchException] if the copy or write fails for any reason
     * (e.g. disk full, permission denied). On failure, any partial output is
     * deleted before the exception propagates.
     */
    fun patch(src: File, cacheDir: File, ftypOffset: Long): File {
        if (!cacheDir.exists()) {
            if (!cacheDir.mkdirs()) {
                throw BrandPatchException(
                    "Cache dir ${cacheDir.absolutePath} does not exist and cannot be created"
                )
            }
        }
        val dst = File(cacheDir, "heic-seq-${System.nanoTime()}.mp4")
        try {
            src.inputStream().use { input ->
                dst.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            RandomAccessFile(dst, "rw").use { raf ->
                // ftyp layout: size(4) + 'ftyp'(4) + major_brand(4) + minor_version(4) + compatible_brands[]
                raf.seek(ftypOffset + 8)
                raf.write(ISO8)
            }
            return dst
        } catch (e: IOException) {
            try { dst.delete() } catch (_: Throwable) {}
            throw BrandPatchException(
                "Failed to write brand-patched temp file ${dst.name}: ${e.message}",
                e
            )
        } catch (e: SecurityException) {
            try { dst.delete() } catch (_: Throwable) {}
            throw BrandPatchException(
                "Permission denied writing brand-patched temp file ${dst.name}: ${e.message}",
                e
            )
        }
    }

    private val ISO8: ByteArray = "iso8".toByteArray(Charsets.US_ASCII)
}
