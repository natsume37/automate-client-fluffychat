import 'package:flutter/material.dart';

class EmployeeWorkTemplateItem {
  final IconData icon;
  final String title;
  final String description;
  final String message;

  const EmployeeWorkTemplateItem({
    required this.icon,
    required this.title,
    required this.description,
    required this.message,
  });
}

class EmployeeWorkTemplateBar extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<EmployeeWorkTemplateItem> templates;
  final ValueChanged<EmployeeWorkTemplateItem> onTemplateTap;

  const EmployeeWorkTemplateBar({
    super.key,
    required this.title,
    required this.subtitle,
    required this.templates,
    required this.onTemplateTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWideLayout = constraints.maxWidth >= 900;

        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          padding: EdgeInsets.all(isWideLayout ? 18 : 14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.colorScheme.primaryContainer.withValues(alpha: 0.72),
                theme.colorScheme.secondaryContainer.withValues(alpha: 0.58),
              ],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.14),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: isWideLayout ? 40 : 34,
                    height: isWideLayout ? 40 : 34,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.assignment_rounded,
                      size: isWideLayout ? 22 : 20,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (isWideLayout)
                Row(
                  children: [
                    for (var i = 0; i < templates.length; i++) ...[
                      Expanded(
                        child: _EmployeeWorkTemplateCard(
                          template: templates[i],
                          onTap: () => onTemplateTap(templates[i]),
                          isWideLayout: true,
                        ),
                      ),
                      if (i != templates.length - 1) const SizedBox(width: 12),
                    ],
                  ],
                )
              else
                SizedBox(
                  height: 84,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: templates.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final template = templates[index];
                      return _EmployeeWorkTemplateCard(
                        template: template,
                        onTap: () => onTemplateTap(template),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _EmployeeWorkTemplateCard extends StatelessWidget {
  final EmployeeWorkTemplateItem template;
  final VoidCallback onTap;
  final bool isWideLayout;

  const _EmployeeWorkTemplateCard({
    required this.template,
    required this.onTap,
    this.isWideLayout = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: isWideLayout ? null : 200,
      child: Material(
        color: Colors.white.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: EdgeInsets.all(isWideLayout ? 16 : 10),
            child: Center(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: isWideLayout ? 38 : 32,
                    height: isWideLayout ? 38 : 32,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      template.icon,
                      size: isWideLayout ? 20 : 17,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  SizedBox(width: isWideLayout ? 14 : 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          template.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          template.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<bool?> showEmployeeWorkTemplatePreviewDialog({
  required BuildContext context,
  required EmployeeWorkTemplateItem template,
  required String previewLabel,
  required String sendLabel,
  required String cancelLabel,
}) {
  final theme = Theme.of(context);

  return showAdaptiveDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog.adaptive(
        title: Text(template.title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  previewLabel,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: SelectableText(
                    template.message,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(sendLabel),
          ),
        ],
      );
    },
  );
}
