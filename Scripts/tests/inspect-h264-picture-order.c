/* Read-only local diagnostic: print numeric packet/POC metadata, never pixels or payloads.
 * Uses the installed FFmpeg development libraries; paths are arguments, not output fields. */
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    AVFormatContext *format = NULL;
    av_log_set_level(AV_LOG_QUIET);
    if (avformat_open_input(&format, argv[1], NULL, NULL) < 0 ||
        avformat_find_stream_info(format, NULL) < 0) return 3;
    int stream = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (stream < 0 || format->streams[stream]->codecpar->codec_id != AV_CODEC_ID_H264) return 4;
    AVStream *st = format->streams[stream];
    AVCodecContext *ctx = avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_H264));
    if (!ctx || avcodec_parameters_to_context(ctx, st->codecpar) < 0) return 5;
    AVCodecParserContext *parser = av_parser_init(AV_CODEC_ID_H264);
    if (!parser) return 6;
    parser->flags |= PARSER_FLAG_COMPLETE_FRAMES;
    ctx->pkt_timebase = st->time_base;
    double start = strtod(argv[2], NULL);
    int count = atoi(argv[3]);
    if (start < 0 || count < 1 || count > 5000) return 7;
    if (start > 0 && av_seek_frame(format, stream, start / av_q2d(st->time_base), AVSEEK_FLAG_BACKWARD) < 0) return 8;
    AVPacket *packet = av_packet_alloc();
    printf("{\"time_base_num\":%d,\"time_base_den\":%d,\"video_delay\":%d,\"packets\":[", st->time_base.num, st->time_base.den, st->codecpar->video_delay);
    int n = 0, reads = 0;
    while (n < count && reads++ < count * 20 && av_read_frame(format, packet) >= 0) {
        if (packet->stream_index == stream) {
            uint8_t *out = NULL;
            int out_size = 0;
            int consumed = av_parser_parse2(parser, ctx, &out, &out_size, packet->data, packet->size, packet->pts, packet->dts, packet->pos);
            if (n++) printf(",");
            printf("{\"pts\":%lld,\"dts\":%lld,\"poc\":%d,\"key\":%s,\"structure\":%d,\"parsed\":%s}",
                (long long)packet->pts, (long long)packet->dts, parser->output_picture_number,
                packet->flags & AV_PKT_FLAG_KEY ? "true" : "false", parser->picture_structure,
                consumed >= 0 && out_size > 0 ? "true" : "false");
        }
        av_packet_unref(packet);
    }
    printf("]}\n");
    av_packet_free(&packet);
    av_parser_close(parser);
    avcodec_free_context(&ctx);
    avformat_close_input(&format);
    return n > 0 ? 0 : 9;
}
