package com.bluebubbles.messaging.services.system

import java.io.File
import java.io.RandomAccessFile

/**
 * Pure ISO BMFF box-tree walker.
 *
 * iOS Live Stickers arrive as `.heics` files with major brand `msf1`. Android's
 * MediaExtractor refuses to open files with that brand even though `iso8` is
 * always in the compatible_brands list, so we cannot use it to inspect the
 * file's structure. This parser walks the box tree directly from raw bytes,
 * letting the caller decide whether the file is a Live Sticker hybrid format
 * (color + alpha auxiliary HEVC tracks in the moov) before applying the brand
 * patch and feeding the patched copy to MediaExtractor.
 *
 * Validates: Requirement 2.1, 2.5, 6.6, 8.1.
 */

/** A single ISO BMFF box header + its byte range in the source file. */
data class Box(
    val type: String,
    val offset: Long,        // absolute file offset of the size field
    val headerSize: Int,     // 8 (32-bit size) or 16 (64-bit size)
    val totalSize: Long,     // size including header; 0 means "to EOF"
    val children: List<Box>  // non-empty only for known container boxes
) {
    val bodyStart: Long get() = offset + headerSize
    val bodyEnd: Long get() = if (totalSize == 0L) Long.MAX_VALUE else offset + totalSize

    /** Recursive search for the first box of [type] anywhere in the subtree. */
    fun findFirst(type: String): Box? {
        if (this.type == type) return this
        for (c in children) {
            val r = c.findFirst(type)
            if (r != null) return r
        }
        return null
    }

    /** Direct children of the given type, in order. */
    fun directChildren(type: String): List<Box> = children.filter { it.type == type }
}

/** The result of parsing the top-level box layout of a file. */
data class BoxTree(val ftypOffset: Long, val topLevel: List<Box>) {
    fun findTopLevel(type: String): Box? = topLevel.firstOrNull { it.type == type }
}

/**
 * `colr` box of subtype `nclx` (the only subtype iOS Live Stickers use).
 *
 * Field meaning per ISO/IEC 14496-12:
 * - colourPrimaries: ITU-T H.273 colour_primaries enum (1=BT.709, 9=BT.2020...)
 * - transferCharacteristics: H.273 transfer_characteristics (1=BT.709, 13=sRGB...)
 * - matrixCoefficients: H.273 matrix_coefficients (1=BT.709, 6=BT.601-NTSC...)
 * - fullRangeFlag: true=PC range (0..255), false=TV range (16..235)
 */
data class NclxColor(
    val colourPrimaries: Int,
    val transferCharacteristics: Int,
    val matrixCoefficients: Int,
    val fullRangeFlag: Boolean
)

/**
 * Result of [BoxParser.detectHybrid]. Carries everything downstream stages need
 * to drive MediaCodec without re-reading the file.
 */
data class HybridFormatInfo(
    val colorTrackId: Int,
    val alphaTrackId: Int,
    val colorTimescale: Int,
    val colorSttsDeltas: List<Int>,
    val alphaTimescale: Int,
    val alphaSttsDeltas: List<Int>,
    val colorNclx: NclxColor?,   // null when the color trak has no colr box
    val alphaNclx: NclxColor?    // alpha tracks rarely have colr; usually null
)

object BoxParser {
    /** Box types whose payload is itself a list of sub-boxes. */
    private val CONTAINERS: Set<String> = setOf(
        "moov", "trak", "mdia", "minf", "stbl", "edts",
        "iprp", "iref", "iinf", "dinf", "udta", "mvex",
        "moof", "traf", "mfra"
    )

    /** Containers whose payload starts with a 4-byte version+flags header. */
    private val FULL_CONTAINERS: Set<String> = setOf("meta")

    private const val MAX_DEPTH = 8

    /**
     * Walks the file's top-level boxes plus the children of containers we
     * recognise, building a tree of [Box]es. Stops at depth [MAX_DEPTH] to
     * guard against pathological input.
     *
     * The walk reads each box header (8 or 16 bytes) and skips the body when
     * the box is not a known container, so memory pressure is bounded by the
     * number of boxes, not by file size.
     */
    fun parse(file: File): BoxTree {
        RandomAccessFile(file, "r").use { raf ->
            val length = raf.length()
            val top = walk(raf, 0L, length, depth = 0)
            val ftyp = top.firstOrNull { it.type == "ftyp" }
                ?: throw IllegalArgumentException("File has no top-level ftyp box: ${file.name}")
            return BoxTree(ftypOffset = ftyp.offset, topLevel = top)
        }
    }

    private fun walk(raf: RandomAccessFile, start: Long, end: Long, depth: Int): List<Box> {
        if (depth > MAX_DEPTH) return emptyList()
        val out = ArrayList<Box>()
        var i = start
        while (i + 8 <= end) {
            raf.seek(i)
            val sizeField = raf.readInt().toLong() and 0xFFFFFFFFL
            val typeBytes = ByteArray(4).also { raf.readFully(it) }
            val type = String(typeBytes, Charsets.US_ASCII)
            var headerSize = 8
            var totalSize = sizeField
            if (sizeField == 1L) {
                totalSize = raf.readLong()
                headerSize = 16
            } else if (sizeField == 0L) {
                totalSize = end - i
            }
            if (totalSize < headerSize.toLong()) {
                // Malformed; skip to end to avoid infinite loop.
                break
            }
            val bodyStart = i + headerSize
            val bodyEnd = i + totalSize
            val children = if (type in CONTAINERS) {
                walk(raf, bodyStart, bodyEnd, depth + 1)
            } else if (type in FULL_CONTAINERS) {
                // meta: payload starts with 4 bytes of version+flags, then sub-boxes.
                walk(raf, bodyStart + 4, bodyEnd, depth + 1)
            } else {
                emptyList()
            }
            out.add(Box(type, i, headerSize, totalSize, children))
            i = bodyEnd
        }
        return out
    }

    /**
     * Returns non-null only when the file matches the iOS Live Sticker hybrid
     * format: a `moov` containing exactly one `pict`-handler track and exactly
     * one `auxv`-handler track, with the `auxv` track's `tref auxl`
     * referencing the `pict` track.
     *
     * The returned [HybridFormatInfo] carries the per-track stts deltas and
     * any `colr nclx` color metadata the caller will propagate to MediaCodec.
     *
     * Validates: Requirements 2.1, 2.5, 6.6, 8.1.
     */
    fun detectHybrid(tree: BoxTree, file: File): HybridFormatInfo? {
        val moov = tree.findTopLevel("moov") ?: return null
        val traks = moov.directChildren("trak")
        if (traks.size < 2) return null

        RandomAccessFile(file, "r").use { raf ->
            // Index every trak by its handler type.
            val byHandler = traks.associateWith { handlerType(raf, it) }
            val pict = traks.singleOrNull { byHandler[it] == "pict" } ?: return null
            val auxv = traks.singleOrNull { byHandler[it] == "auxv" } ?: return null

            val pictTrackId = trackId(raf, pict) ?: return null
            val auxvTrackId = trackId(raf, auxv) ?: return null

            val auxlRefs = trefAuxl(raf, auxv) ?: return null
            if (auxlRefs.size != 1 || auxlRefs[0] != pictTrackId) return null

            val colorTimescale = mdhdTimescale(raf, pict) ?: return null
            val alphaTimescale = mdhdTimescale(raf, auxv) ?: return null
            val colorDeltas = readSttsDeltas(raf, pict)
            val alphaDeltas = readSttsDeltas(raf, auxv)
            if (colorDeltas.isEmpty() || alphaDeltas.isEmpty()) return null

            val colorNclx = readColrNclx(raf, pict)
            val alphaNclx = readColrNclx(raf, auxv)

            return HybridFormatInfo(
                colorTrackId = pictTrackId,
                alphaTrackId = auxvTrackId,
                colorTimescale = colorTimescale,
                colorSttsDeltas = colorDeltas,
                alphaTimescale = alphaTimescale,
                alphaSttsDeltas = alphaDeltas,
                colorNclx = colorNclx,
                alphaNclx = alphaNclx
            )
        }
    }

    // ---- field readers -----------------------------------------------------

    /** Returns the 4-character handler_type from `trak/mdia/hdlr`, or null. */
    private fun handlerType(raf: RandomAccessFile, trak: Box): String? {
        val hdlr = trak.findFirst("hdlr") ?: return null
        // hdlr layout: version(1) + flags(3) + predefined(4) + handler_type(4) + ...
        raf.seek(hdlr.bodyStart + 8)
        val bytes = ByteArray(4).also { raf.readFully(it) }
        return String(bytes, Charsets.US_ASCII)
    }

    /** Returns the track_id from `trak/tkhd`, or null if tkhd is missing. */
    private fun trackId(raf: RandomAccessFile, trak: Box): Int? {
        val tkhd = trak.findFirst("tkhd") ?: return null
        raf.seek(tkhd.bodyStart)
        val version = raf.readByte().toInt() and 0xFF
        // Skip flags(3) + creation_time + modification_time.
        val skip = if (version == 0) 3 + 4 + 4 else 3 + 8 + 8
        raf.seek(tkhd.bodyStart + 1 + skip)
        return raf.readInt()
    }

    /** Returns the list of track_ids referenced by the `tref auxl` box. */
    private fun trefAuxl(raf: RandomAccessFile, trak: Box): List<Int>? {
        // tref is a container box, but we wrote walk() to leave its children
        // unparsed (it's not in CONTAINERS) so we have to walk it inline here.
        val tref = trak.findFirst("tref") ?: return null
        raf.seek(tref.bodyStart)
        val end = tref.bodyEnd
        var pos = tref.bodyStart
        while (pos + 8 <= end) {
            raf.seek(pos)
            val size = raf.readInt().toLong() and 0xFFFFFFFFL
            val typeBytes = ByteArray(4).also { raf.readFully(it) }
            val type = String(typeBytes, Charsets.US_ASCII)
            if (type == "auxl") {
                // body is a list of u32 track_ids
                val n = ((pos + size) - (pos + 8)) / 4
                val ids = IntArray(n.toInt())
                for (i in 0 until n.toInt()) {
                    ids[i] = raf.readInt()
                }
                return ids.toList()
            }
            pos += size
        }
        return null
    }

    /** Returns the timescale from `trak/mdia/mdhd`. */
    private fun mdhdTimescale(raf: RandomAccessFile, trak: Box): Int? {
        val mdhd = trak.findFirst("mdhd") ?: return null
        raf.seek(mdhd.bodyStart)
        val version = raf.readByte().toInt() and 0xFF
        // Skip flags(3) + creation_time + modification_time.
        val skip = if (version == 0) 3 + 4 + 4 else 3 + 8 + 8
        raf.seek(mdhd.bodyStart + 1 + skip)
        return raf.readInt()
    }

    /**
     * Returns per-frame sample-delta values from `stts` in sample order.
     *
     * stts entries are run-length encoded: `(sample_count, sample_delta)`. We
     * expand them so the caller can map each frame index to its delay.
     */
    private fun readSttsDeltas(raf: RandomAccessFile, trak: Box): List<Int> {
        val stts = trak.findFirst("stts") ?: return emptyList()
        // stts: version(1) + flags(3) + entry_count(4) + entries
        raf.seek(stts.bodyStart + 4)
        val entryCount = raf.readInt()
        if (entryCount <= 0) return emptyList()
        val out = ArrayList<Int>()
        for (i in 0 until entryCount) {
            val sampleCount = raf.readInt()
            val sampleDelta = raf.readInt()
            if (sampleCount <= 0 || sampleCount > 10_000) return emptyList()
            for (j in 0 until sampleCount) out.add(sampleDelta)
        }
        return out
    }

    /**
     * Returns the `colr nclx` box from the first `hvc1` SampleEntry inside
     * `trak/mdia/minf/stbl/stsd`, or null if absent.
     */
    private fun readColrNclx(raf: RandomAccessFile, trak: Box): NclxColor? {
        val stsd = trak.findFirst("stsd") ?: return null
        // stsd: version(1) + flags(3) + entry_count(4) + SampleEntry[entry_count]
        raf.seek(stsd.bodyStart + 4)
        val n = raf.readInt()
        if (n <= 0) return null

        // Walk to first sample entry.
        var pos = stsd.bodyStart + 8
        val end = stsd.bodyEnd
        if (pos + 8 > end) return null
        raf.seek(pos)
        val seSize = raf.readInt().toLong() and 0xFFFFFFFFL
        val seTypeBytes = ByteArray(4).also { raf.readFully(it) }
        val seType = String(seTypeBytes, Charsets.US_ASCII)
        // We only support hvc1/hev1 sample entries.
        if (seType != "hvc1" && seType != "hev1") return null

        // VisualSampleEntry: 8 byte SampleEntry header (already consumed) +
        // 6 bytes reserved + 2 bytes data_reference_index + 16 reserved
        // + 2 width + 2 height + 4 horizresolution + 4 vertresolution
        // + 4 reserved + 2 frame_count + 32 compressorname + 2 depth + 2 pre_defined.
        // Total = 78 bytes after the 8-byte header.
        val subStart = pos + 8 + 78
        val subEnd = pos + seSize
        return walkForColr(raf, subStart, subEnd)
    }

    private fun walkForColr(raf: RandomAccessFile, start: Long, end: Long): NclxColor? {
        var pos = start
        while (pos + 8 <= end) {
            raf.seek(pos)
            val size = raf.readInt().toLong() and 0xFFFFFFFFL
            val typeBytes = ByteArray(4).also { raf.readFully(it) }
            val type = String(typeBytes, Charsets.US_ASCII)
            if (type == "colr") {
                val subTypeBytes = ByteArray(4).also { raf.readFully(it) }
                val subType = String(subTypeBytes, Charsets.US_ASCII)
                if (subType == "nclx") {
                    val cp = raf.readUnsignedShort()
                    val tc = raf.readUnsignedShort()
                    val mc = raf.readUnsignedShort()
                    val flags = raf.readByte().toInt() and 0xFF
                    val fullRange = (flags and 0x80) != 0
                    return NclxColor(cp, tc, mc, fullRange)
                }
            }
            if (size == 0L) break
            pos += size
        }
        return null
    }
}
