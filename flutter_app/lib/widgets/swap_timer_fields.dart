import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'app_text_field.dart';

/// Two timer inputs with a swap button between them; swapping animates the
/// inputs trading places and flips their labels.
class SwapTimerFields extends StatefulWidget {
  const SwapTimerFields({
    super.key,
    required this.onController,
    required this.offController,
  });

  final TextEditingController onController;
  final TextEditingController offController;

  @override
  State<SwapTimerFields> createState() => _SwapTimerFieldsState();
}

class _SwapTimerFieldsState extends State<SwapTimerFields>
    with SingleTickerProviderStateMixin {
  static const _midHeight = 56.0;

  final _onKey = GlobalKey();
  final _offKey = GlobalKey();
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _anim,
    curve: Curves.easeInOutCubic,
  );

  bool _swapped = false;
  double _topShift = 0;
  double _bottomShift = 0;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  double _height(GlobalKey key) => key.currentContext?.size?.height ?? 0;

  Future<void> _swap() async {
    if (_anim.isAnimating) return;
    final topKey = _swapped ? _offKey : _onKey;
    final bottomKey = _swapped ? _onKey : _offKey;
    _topShift = _height(bottomKey) + _midHeight;
    _bottomShift = -(_height(topKey) + _midHeight);
    await _anim.forward(from: 0);
    if (!mounted) return;
    setState(() => _swapped = !_swapped);
    _anim.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    final onField = _SwapSlot(
      key: _onKey,
      animation: _curve,
      isTop: !_swapped,
      topShift: _topShift,
      bottomShift: _bottomShift,
      child: AppTextField(
        label: _swapped ? 'Thời gian bật kể từ khi tắt' : 'Thời gian bật',
        controller: widget.onController,
        keyboardType: TextInputType.number,
        helper: _swapped
            ? 'Phút. Tải tự bật sau khoảng thời gian đặt trước kể từ khi được tắt; 0: không tự bật.'
            : 'Phút. Tải tự bật sau khoảng thời gian đặt trước.',
      ),
    );
    final offField = _SwapSlot(
      key: _offKey,
      animation: _curve,
      isTop: _swapped,
      topShift: _topShift,
      bottomShift: _bottomShift,
      child: AppTextField(
        label: _swapped ? 'Thời gian tắt' : 'Thời gian tắt kể từ khi bật',
        controller: widget.offController,
        keyboardType: TextInputType.number,
        helper: _swapped
            ? 'Phút. Tải tự tắt sau khoảng thời gian đặt trước.'
            : 'Phút. Tải tự tắt sau khoảng thời gian đặt trước kể từ khi được bật; 0: không tự tắt.',
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _swapped ? offField : onField,
        SizedBox(
          height: _midHeight,
          child: Center(
            child: AnimatedBuilder(
              animation: _curve,
              builder: (context, child) => Transform.rotate(
                angle: _curve.value * math.pi,
                child: child,
              ),
              child: _SwapButton(onTap: _swap),
            ),
          ),
        ),
        _swapped ? onField : offField,
      ],
    );
  }
}

class _SwapSlot extends StatelessWidget {
  const _SwapSlot({
    super.key,
    required this.animation,
    required this.isTop,
    required this.topShift,
    required this.bottomShift,
    required this.child,
  });

  final Animation<double> animation;
  final bool isTop;
  final double topShift;
  final double bottomShift;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, animation.value * (isTop ? topShift : bottomShift)),
        child: child,
      ),
    );
  }
}

class _SwapButton extends StatelessWidget {
  const _SwapButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.mint,
      shape: const CircleBorder(side: BorderSide(color: AppColors.primarySoft)),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: const SizedBox(
          width: 40,
          height: 40,
          child: Icon(Icons.swap_vert_rounded, color: AppColors.primary),
        ),
      ),
    );
  }
}
