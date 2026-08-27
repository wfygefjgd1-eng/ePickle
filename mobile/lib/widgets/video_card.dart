import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../utils/http_headers.dart';

class VideoCard extends StatelessWidget {
  final VideoItem item;
  final VoidCallback onTap;

  const VideoCard({super.key, required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final headers = AppHttpHeaders.forMediaUrl(item.thumb ?? item.url);
    return RepaintBoundary(
      child: Card(
        color: const Color(0xFF2A2A2A),
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: InkWell(
          onTap: onTap,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final thumbnailWidth = (constraints.maxWidth * 0.4).clamp(
                112.0,
                140.0,
              );
              final thumbnailHeight = thumbnailWidth * 88 / 140;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: thumbnailWidth,
                    height: thumbnailHeight,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (item.thumb != null && item.thumb!.isNotEmpty)
                          CachedNetworkImage(
                            imageUrl: item.thumb!,
                            httpHeaders: headers,
                            fit: BoxFit.cover,
                            memCacheWidth: 200,
                            memCacheHeight: 125,
                            placeholder: (_, __) =>
                                Container(color: const Color(0xFF1A1A1A)),
                            errorWidget: (_, __, ___) => Container(
                              color: const Color(0xFF1A1A1A),
                              child: const Icon(
                                Icons.broken_image,
                                color: Colors.grey,
                              ),
                            ),
                          )
                        else
                          Container(
                            color: const Color(0xFF1A1A1A),
                            child: const Icon(
                              Icons.play_circle_outline,
                              color: Colors.grey,
                              size: 36,
                            ),
                          ),
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              item.duration,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      child: Text(
                        item.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFEEEEEE),
                          fontSize: 14,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
