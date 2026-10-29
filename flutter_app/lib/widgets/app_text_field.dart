import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.label,
    this.controller,
    this.obscureText = false,
    this.hint,
    this.helper,
    this.keyboardType,
    this.suffixIcon,
    this.enabled = true,
    this.labelTrailing,
    this.errorText,
    this.onChanged,
  });

  final String label;

  /// Turns the field red and shows the message under it.
  final String? errorText;
  final ValueChanged<String>? onChanged;

  /// Shown at the right end of the label row.
  final Widget? labelTrailing;
  final TextEditingController? controller;
  final bool obscureText;
  final String? hint;
  final String? helper;
  final TextInputType? keyboardType;
  final Widget? suffixIcon;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (labelTrailing == null)
          Text(label, style: AppTextStyles.label)
        else
          Row(
            children: [
              Expanded(child: Text(label, style: AppTextStyles.label)),
              labelTrailing!,
            ],
          ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscureText,
          keyboardType: keyboardType,
          enabled: enabled,
          onChanged: onChanged,
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          style: AppTextStyles.fieldHint,
          cursorColor: AppColors.primary,
          decoration: InputDecoration(
            hintText: hint,
            errorText: errorText,
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppColors.danger),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppColors.danger, width: 1.4),
            ),
            suffixIcon: suffixIcon,
            hintStyle: AppTextStyles.bodySecondary,
            filled: true,
            fillColor: AppColors.surface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppColors.inputBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(
                color: AppColors.primary,
                width: 1.4,
              ),
            ),
          ),
        ),
        if (helper != null) ...[
          const SizedBox(height: 6),
          Text(helper!, style: AppTextStyles.caption),
        ],
      ],
    );
  }
}

class AppPasswordField extends StatefulWidget {
  const AppPasswordField({
    super.key,
    required this.label,
    this.controller,
    this.helper,
  });

  final String label;
  final TextEditingController? controller;
  final String? helper;

  @override
  State<AppPasswordField> createState() => _AppPasswordFieldState();
}

class _AppPasswordFieldState extends State<AppPasswordField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    return AppTextField(
      label: widget.label,
      controller: widget.controller,
      helper: widget.helper,
      obscureText: _hidden,
      suffixIcon: IconButton(
        onPressed: () => setState(() => _hidden = !_hidden),
        icon: Icon(
          _hidden ? Icons.visibility_off_rounded : Icons.visibility_rounded,
          size: 22,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}
