import 'package:flutter/material.dart';

import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/utils/url_launcher.dart';

final RegExp _amapTaxiUriPattern = RegExp(
  "amapuri://drive/takeTaxi\\?[^\\s<>\"']+",
  caseSensitive: false,
);

class AmapTaxiLinkData {
  final String rawUrl;
  final Uri uri;
  final String? pickupName;
  final String? destinationName;
  final String? pickupCoordinates;
  final String? destinationCoordinates;

  const AmapTaxiLinkData._({
    required this.rawUrl,
    required this.uri,
    required this.pickupName,
    required this.destinationName,
    required this.pickupCoordinates,
    required this.destinationCoordinates,
  });

  static List<AmapTaxiLinkData> extractFromText(String text) {
    if (text.isEmpty) return const [];
    return _amapTaxiUriPattern
        .allMatches(text)
        .map((match) => match.group(0))
        .whereType<String>()
        .map(_parse)
        .whereType<AmapTaxiLinkData>()
        .toList(growable: false);
  }

  static bool hasLeadingText(String text) {
    if (text.isEmpty) return false;
    final firstMatch = _amapTaxiUriPattern.firstMatch(text);
    if (firstMatch == null || firstMatch.start <= 0) {
      return false;
    }
    return text.substring(0, firstMatch.start).trim().isNotEmpty;
  }

  static String stripFromText(String text) {
    if (text.isEmpty) return text;
    return text
        .replaceAll(_amapTaxiUriPattern, '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  static AmapTaxiLinkData? _parse(String rawUrl) {
    final normalizedUrl = rawUrl.replaceAll('&amp;', '&');
    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null ||
        uri.scheme != 'amapuri' ||
        uri.host != 'drive' ||
        uri.path != '/takeTaxi') {
      return null;
    }

    String? pickValue(String key) {
      final value = uri.queryParameters[key]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    String? buildCoordinateLabel(String latKey, String lonKey) {
      final lat = pickValue(latKey);
      final lon = pickValue(lonKey);
      if (lat == null || lon == null) return null;
      return '$lat, $lon';
    }

    return AmapTaxiLinkData._(
      rawUrl: normalizedUrl,
      uri: uri,
      pickupName: pickValue('sname'),
      destinationName: pickValue('dname'),
      pickupCoordinates: buildCoordinateLabel('slat', 'slon'),
      destinationCoordinates: buildCoordinateLabel('dlat', 'dlon'),
    );
  }
}

class AmapTaxiCard extends StatelessWidget {
  final AmapTaxiLinkData link;

  const AmapTaxiCard({
    required this.link,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final titleColor = theme.colorScheme.onSurface;
    final subtitleColor = theme.colorScheme.onSurfaceVariant;

    String resolveLocation(String? name, String? coordinates) {
      if (name != null && name.isNotEmpty) return name;
      if (coordinates != null && coordinates.isNotEmpty) return coordinates;
      return l10n.taxiRideUnknownLocation;
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withAlpha(160),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.local_taxi_rounded,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.taxiRideCardTitle,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _TaxiLocationRow(
            icon: Icons.trip_origin_rounded,
            label: l10n.taxiRidePickup,
            value: resolveLocation(link.pickupName, link.pickupCoordinates),
          ),
          const SizedBox(height: 10),
          _TaxiLocationRow(
            icon: Icons.location_on_rounded,
            label: l10n.taxiRideDestination,
            value: resolveLocation(
              link.destinationName,
              link.destinationCoordinates,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            l10n.taxiRideCardHint,
            style: TextStyle(
              color: subtitleColor,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => UrlLauncher(context, link.rawUrl).launchUrl(),
              icon: const Icon(Icons.navigation_rounded),
              label: Text(l10n.taxiRideAction),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaxiLocationRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _TaxiLocationRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            icon,
            size: 16,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
