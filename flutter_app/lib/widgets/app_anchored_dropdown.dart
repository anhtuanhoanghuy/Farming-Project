import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

class AppDropdownOption<T> {
  const AppDropdownOption({required this.value, required this.label});

  final T value;
  final String label;
}

class AppAnchoredDropdownField<T> extends StatefulWidget {
  const AppAnchoredDropdownField({
    super.key,
    required this.value,
    required this.options,
    required this.enabled,
    required this.onChanged,
    this.hint,
    this.errorText,
  });

  final T? value;
  final List<AppDropdownOption<T>> options;
  final bool enabled;
  final ValueChanged<T> onChanged;
  final String? hint;
  final String? errorText;

  @override
  State<AppAnchoredDropdownField<T>> createState() =>
      _AppAnchoredDropdownFieldState<T>();
}

class _AppAnchoredDropdownFieldState<T>
    extends State<AppAnchoredDropdownField<T>> {
  final _portalController = OverlayPortalController();
  final _layerLink = LayerLink();
  final _targetKey = GlobalKey();
  bool _isOpen = false;

  String? get _selectedLabel {
    for (final option in widget.options) {
      if (option.value == widget.value) return option.label;
    }
    return null;
  }

  Future<void> _open() async {
    final target = _targetKey.currentContext;
    if (!widget.enabled || widget.options.isEmpty || target == null) return;
    await Scrollable.ensureVisible(
      target,
      alignment: 0.12,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
    if (!mounted) return;
    setState(() => _isOpen = true);
    _portalController.show();
  }

  void _close() {
    if (!_isOpen) return;
    _portalController.hide();
    if (mounted) setState(() => _isOpen = false);
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portalController,
    overlayChildBuilder: (overlayContext) {
      final target = _targetKey.currentContext?.findRenderObject();
      final overlay = Overlay.of(overlayContext).context.findRenderObject();
      final targetBox = target is RenderBox ? target : null;
      final overlayBox = overlay is RenderBox ? overlay : null;
      final width = targetBox?.size.width ?? 200.0;
      final bottom = targetBox != null && overlayBox != null
          ? targetBox.localToGlobal(Offset.zero, ancestor: overlayBox).dy +
                targetBox.size.height
          : 0.0;
      final availableHeight = overlayBox == null
          ? 220.0
          : math.max(0.0, overlayBox.size.height - bottom - 8.0);
      final maxHeight = math.min(240.0, availableHeight);

      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _close,
            ),
          ),
          Align(
            alignment: Alignment.topLeft,
            child: CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomLeft,
              followerAnchor: Alignment.topLeft,
              offset: const Offset(0, 4),
              child: Material(
                color: AppColors.surface,
                elevation: 8,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: width,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: maxHeight < 48.0 ? 48.0 : maxHeight,
                    ),
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      shrinkWrap: true,
                      children: [
                        for (final option in widget.options)
                          InkWell(
                            onTap: () {
                              widget.onChanged(option.value);
                              _close();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      option.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTextStyles.body,
                                    ),
                                  ),
                                  if (option.value == widget.value)
                                    const Icon(
                                      Icons.check_rounded,
                                      size: 18,
                                      color: AppColors.primary,
                                    ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
    child: CompositedTransformTarget(
      link: _layerLink,
      child: SizedBox(
        key: _targetKey,
        width: double.infinity,
        child: InkWell(
          onTap: widget.enabled ? _open : null,
          borderRadius: BorderRadius.circular(12),
          child: InputDecorator(
            isFocused: _isOpen,
            isEmpty: _selectedLabel == null,
            decoration: InputDecoration(
              enabled: widget.enabled,
              errorText: widget.errorText,
              filled: true,
              fillColor: AppColors.surface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 13,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: AppColors.primary,
                  width: 1.4,
                ),
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.danger),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _selectedLabel ?? widget.hint ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _selectedLabel == null
                        ? AppTextStyles.bodySecondary
                        : AppTextStyles.body,
                  ),
                ),
                Icon(
                  _isOpen
                      ? Icons.arrow_drop_up_rounded
                      : Icons.arrow_drop_down_rounded,
                  color: widget.enabled
                      ? AppColors.textSecondary
                      : AppColors.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
