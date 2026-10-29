import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

class HeroBanner extends StatefulWidget {
  const HeroBanner({super.key});

  @override
  State<HeroBanner> createState() => _HeroBannerState();
}

class _HeroBannerState extends State<HeroBanner> {
  static const _banners = [
    _BannerContent(
      icon: Icons.home_outlined,
      title: 'Nâng tầm tổ ấm\nSống thông minh hơn',
      subtitle: 'Điều khiển chiếu sáng, điều hòa và thiết bị mọi lúc',
    ),
    _BannerContent(
      icon: Icons.waves_rounded,
      title: 'Nắm rõ ao nuôi\nVận hành thảnh thơi',
      subtitle: 'Quản lý và tự động hóa ao nuôi toàn diện',
    ),
    _BannerContent(
      icon: Icons.warehouse_outlined,
      title: 'Làm chủ trang trại\nChăn nuôi hiệu quả',
      subtitle: 'Giám sát nhiệt độ, thông gió và cấp nước tự động',
    ),
    _BannerContent(
      icon: Icons.grass_rounded,
      title: 'Chăm chút vườn cây\nTưới tiêu thông minh',
      subtitle: 'Theo dõi độ ẩm đất, điều khiển máy bơm và van từ xa',
    ),
  ];

  final _pageController = PageController();
  Timer? _timer;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_pageController.hasClients) return;
      final nextPage = _currentPage + 1;
      await _pageController.animateToPage(
        nextPage,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOut,
      );
      if (nextPage == _banners.length && mounted && _pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 503 / 268,
          child: PageView.builder(
            controller: _pageController,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _banners.length + 1,
            onPageChanged: (page) =>
                setState(() => _currentPage = page % _banners.length),
            itemBuilder: (context, index) => _BannerCard(
              content: _banners[index % _banners.length],
            ),
          ),
        ),
      ],
    );
  }
}

class _BannerContent {
  const _BannerContent({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({required this.content});

  final _BannerContent content;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 20, 18),
      decoration: BoxDecoration(
        color: AppColors.hero,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(content.icon, color: AppColors.wave, size: 48),
          const SizedBox(height: 7),
          Text(
            content.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.heroTitle.copyWith(
              fontSize: 24,
              height: 1.16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            content.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.heroSubtitle.copyWith(fontSize: 12),
          ),
        ],
      ),
    );
  }
}
