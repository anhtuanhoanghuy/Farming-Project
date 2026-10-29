import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// Three-dot header menu styled like the rest of the app.
class AppMoreMenu<T> extends StatelessWidget {
  const AppMoreMenu({
    super.key,
    required this.itemBuilder,
    this.onSelected,
  });

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T>? onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      icon: const Icon(Icons.more_vert, color: AppColors.textPrimary),
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shadowColor: AppColors.shadow,
      offset: const Offset(0, 44),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      itemBuilder: itemBuilder,
      onSelected: onSelected,
    );
  }
}

/// Menu row with a trailing switch that keeps the menu open when toggled.
class MenuSwitchRow extends StatefulWidget {
  const MenuSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.width = 230,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final double width;

  @override
  State<MenuSwitchRow> createState() => _MenuSwitchRowState();
}

class _MenuSwitchRowState extends State<MenuSwitchRow> {
  late bool _value = widget.value;

  @override
  void didUpdateWidget(covariant MenuSwitchRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _value = widget.value;
    }
  }

  void _set(bool v) {
    setState(() => _value = v);
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _set(!_value),
      child: SizedBox(
        width: widget.width,
        child: Row(
          children: [
            Expanded(
              child: Text(widget.label, style: AppTextStyles.bodyMedium),
            ),
            const SizedBox(width: 8),
            Switch(value: _value, onChanged: _set),
          ],
        ),
      ),
    );
  }
}
