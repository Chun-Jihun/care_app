package org.carenotebook.care_notebook

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build

/** Streams PCM to the speaker without creating a decrypted audio file. */
internal class VisitAudioPlayback {
    private var track: AudioTrack? = null
    private var frames = 0
    private var finishing = false

    fun start() {
        stop()
        val minimum = AudioTrack.getMinBufferSize(16000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        check(minimum > 0)
        val next = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(16000)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(minimum)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        try {
            check(next.state == AudioTrack.STATE_INITIALIZED)
            if (Build.VERSION.SDK_INT >= 31) next.startThresholdInFrames = 1
            next.play()
            track = next
        } catch (error: Exception) {
            next.release()
            throw error
        }
    }

    fun write(pcm: ByteArray, offset: Int): Int {
        require(pcm.size in 2..32000 && pcm.size % 2 == 0)
        require(offset in 0 until pcm.size && offset % 2 == 0)
        val written = checkNotNull(track).write(pcm, offset, pcm.size - offset, AudioTrack.WRITE_NON_BLOCKING)
        check(written >= 0 && written % 2 == 0)
        frames += written / 2
        return written
    }

    fun drained(): Boolean {
        val output = checkNotNull(track)
        if (output.playbackHeadPosition >= frames) return true
        if (!finishing) {
            // Fill the output buffer so even a short final fragment can start after an underrun.
            val silence = ByteArray(output.bufferSizeInFrames * 2)
            check(output.write(silence, 0, silence.size, AudioTrack.WRITE_NON_BLOCKING) >= 0)
            finishing = true
        }
        return false
    }

    fun stop() {
        track?.release()
        track = null
        frames = 0
        finishing = false
    }
}
