import 'package:flutter/material.dart';

import '../theme/app_text_styles.dart';

/// Row of separate rounded choice buttons; the selected one is filled and
/// shows a check mark.
class AppChoiceButtons<T> extends StatelessWidget {
  const AppChoiceButtons({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  static const _accent = Color(0xFF447573);
  static const _unselectedBorder = Color(0xFFDCE6E6);

  /// Value and label of each button, in display order.
  final List<(T, String)> options;
  final T selected;

  /// Null disables every button.
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(child: _button(options[i].$1, options[i].$2)),
        ],
      ],
    );
  }

  Widget _button(T value, String label) {
    final isSelected = value == selected;
    final textStyle = AppTextStyles.button.copyWith(
      fontWeight: FontWeight.w700,
      color: isSelected ? Colors.white : _accent,
    );
    return Material(
      color: isSelected ? _accent : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isSelected ? _accent : _unselectedBorder,
          width: 1.5,
        ),
      ),
      child: InkWell(
        customBorder: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        onTap: onChanged == null ? null : () => onChanged!(value),
        child: SizedBox(
          height: 56,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: textStyle),
                if (isSelected) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.check_rounded, size: 18, color: Colors.white),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
