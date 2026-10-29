import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// A time field that opens a scrolling wheel (hours | minutes, 24 h) in a
/// bottom sheet, like the alarm apps, instead of asking for typed text.
class TimeWheelField extends StatelessWidget {
  const TimeWheelField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.errorText,
    this.enabled = true,
  });

  final String label;
  final TimeOfDay? value;
  final ValueChanged<TimeOfDay> onChanged;

  /// Turns the field red and shows the message under it.
  final String? errorText;
  final bool enabled;

  static String format(TimeOfDay time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  Future<void> _pick(BuildContext context) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final picked = await showModalBottomSheet<TimeOfDay>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _TimeWheelSheet(
        title: label,
        initial: value ?? const TimeOfDay(hour: 6, minute: 0),
      ),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final hasError = errorText != null;
    final color = hasError ? AppColors.danger : AppColors.inputBorder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.label),
        const SizedBox(height: 8),
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? () => _pick(context) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color, width: hasError ? 1.4 : 1),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value == null ? 'Chọn giờ' : format(value!),
                    style: value == null
                        ? AppTextStyles.bodySecondary
                        : AppTextStyles.fieldHint.copyWith(
                            color: enabled ? null : AppColors.disabledText,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 6),
          Text(
            errorText!,
            style: AppTextStyles.caption.copyWith(color: AppColors.danger),
          ),
        ],
      ],
    );
  }
}

class _TimeWheelSheet extends StatefulWidget {
  const _TimeWheelSheet({required this.title, required this.initial});

  final String title;
  final TimeOfDay initial;

  @override
  State<_TimeWheelSheet> createState() => _TimeWheelSheetState();
}

class _TimeWheelSheetState extends State<_TimeWheelSheet> {
  late TimeOfDay _selected = widget.initial;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Hủy'),
                ),
                Expanded(
                  child: Text(
                    widget.title,
                    textAlign: TextAlign.center,
                    style: AppTextStyles.cardTitle,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, _selected),
                  child: const Text('Xong'),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 200,
            child: CupertinoTheme(
              data: const CupertinoThemeData(
                textTheme: CupertinoTextThemeData(
                  dateTimePickerTextStyle: TextStyle(
                    fontSize: 24,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.time,
                use24hFormat: true,
                initialDateTime: DateTime(
                  2000,
                  1,
                  1,
                  widget.initial.hour,
                  widget.initial.minute,
                ),
                onDateTimeChanged: (value) => _selected = TimeOfDay(
                  hour: value.hour,
                  minute: value.minute,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
