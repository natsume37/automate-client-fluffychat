import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tobias/tobias.dart' as tobias;
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/backend/api_client.dart';
import 'payment_success_page.dart';

/// 支付状态枚举
enum PaymentState {
  idle,           // 空闲，等待用户点击支付
  creatingOrder,  // 正在创建订单
  awaitingAlipay, // 等待用户从支付宝返回
  verifying,      // 正在验证支付结果
  success,        // 支付成功
  failed,         // 支付失败
}

/// 订单确认页面
/// 标准方案：使用页面级状态 + WidgetsBindingObserver 处理支付流程
class OrderPage extends StatefulWidget {
  final double amount;

  const OrderPage({
    super.key,
    required this.amount,
  });

  @override
  State<OrderPage> createState() => _OrderPageState();
}

class _OrderPageState extends State<OrderPage> with WidgetsBindingObserver {
  // 选中的支付方式：0 = 微信, 1 = 支付宝, 2 = 银行卡
  int _selectedPayment = 1; // 默认选中支付宝

  // 订单号（固定生成一次）
  late final String _orderNo;

  // 倒计时（秒）
  int _countdown = 15 * 60; // 15分钟
  Timer? _timer;

  // ========== 支付状态管理（核心改动） ==========
  PaymentState _paymentState = PaymentState.idle;
  String _statusMessage = '';
  String? _pendingOutTradeNo;  // 待验证的订单号

  // 真实订单数据（从后端返回）
  double? _realTotalAmount;
  int? _realCreditsAmount;

  // 主题绿色
  static const Color _primaryGreen = Color(0xFF4CAF50);
  static const Color _lightGreen = Color(0xFFE8F5E9);

  @override
  void initState() {
    super.initState();
    _orderNo = 'ORD${DateTime.now().millisecondsSinceEpoch.toString().substring(4)}';
    _startCountdown();

    // 注册生命周期监听器
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _timer?.cancel();
    // 移除生命周期监听器
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 生命周期回调：App 从后台恢复时触发
  /// 这是处理支付宝返回的标准入口
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    print('📱 [LIFECYCLE] App state changed to: $state');

    if (state == AppLifecycleState.resumed) {
      // App 从后台恢复（用户从支付宝返回）
      if (_paymentState == PaymentState.awaitingAlipay && _pendingOutTradeNo != null) {
        print('📱 [LIFECYCLE] Resumed from Alipay, starting verification...');
        // 开始验证支付结果
        _verifyPaymentOnResume();
      }
    }
  }

  void _startCountdown() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown > 0) {
        setState(() {
          _countdown--;
        });
      } else {
        timer.cancel();
        // 超时处理
        if (mounted && _paymentState == PaymentState.idle) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(L10n.of(context).orderTimeout),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    });
  }

  String get _countdownText {
    final minutes = _countdown ~/ 60;
    final seconds = _countdown % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// 更新支付状态（统一入口）
  void _updatePaymentState(PaymentState state, {String message = ''}) {
    if (!mounted) return;
    setState(() {
      _paymentState = state;
      _statusMessage = message;
    });
    print('📊 [STATE] Payment state: $state, message: $message');
  }

  Future<void> _onConfirmPayment() async {
    final l10n = L10n.of(context);
    final apiClient = context.read<PsygoApiClient>();

    // 更新状态为创建订单中
    _updatePaymentState(PaymentState.creatingOrder, message: l10n.walletProcessing);

    try {
      // 1. 调用后端创建订单
      final orderResponse = await apiClient.createRechargeOrder(widget.amount);

      print('===== Alipay Order Debug =====');
      print('OutTradeNo: ${orderResponse.outTradeNo}');
      print('TotalAmount: ${orderResponse.totalAmount}');
      print('CreditsAmount: ${orderResponse.creditsAmount}');
      print('OrderString length: ${orderResponse.orderString.length}');
      print('==============================');

      if (!mounted) {
        print('⚠️ [MOUNT-CHECK-1] Widget unmounted after order creation');
        return;
      }

      // 2. 保存订单号和真实金额数据，切换状态为等待支付宝
      _pendingOutTradeNo = orderResponse.outTradeNo;
      _realTotalAmount = orderResponse.totalAmount;
      _realCreditsAmount = orderResponse.creditsAmount;
      _updatePaymentState(PaymentState.awaitingAlipay, message: '正在跳转支付宝...');

      // 3. 调用支付宝 SDK
      print('🚀 Calling tobias.pay() with ONLINE environment...');
      final payResult = await tobias.Tobias().pay(
        orderResponse.orderString,
        evn: tobias.AliPayEvn.online,
      );

      // 📋 日志：打印支付结果
      print('===== Alipay Pay Result =====');
      print('Full result: $payResult');
      print('resultStatus: ${payResult['resultStatus']}');
      print('memo: ${payResult['memo']}');
      print('=============================');

      // 4. 处理支付结果
      final resultStatus = payResult['resultStatus']?.toString();
      print('📊 [RESULT-STATUS] resultStatus = $resultStatus');

      if (resultStatus == '9000') {
        // ✅ 支付成功 - 验证订单
        await _handlePaymentSuccess(apiClient, orderResponse.outTradeNo);

      } else if (resultStatus == '8000') {
        // ⏳ 支付处理中 - 轮询
        await _handlePaymentProcessing(apiClient, orderResponse.outTradeNo);

      } else if (resultStatus == '6001') {
        // ❌ 用户取消
        print('❌ [CANCELED] User canceled payment');
        _updatePaymentState(PaymentState.idle);
        _showSnackBar(l10n.orderCanceled);

      } else if (resultStatus == '6002') {
        // ❌ 网络错误
        print('❌ [NETWORK-ERROR] Network error occurred');
        _updatePaymentState(PaymentState.idle);
        final memo = payResult['memo'] as String? ?? '网络连接出错';
        _showSnackBar('$memo (code: $resultStatus)');

      } else {
        // ❌ 其他错误
        print('❌ [FAILED] Payment failed with status: $resultStatus');
        _updatePaymentState(PaymentState.idle);
        final memo = payResult['memo'] as String? ?? l10n.orderPaymentFailed;
        _showSnackBar('${l10n.orderPaymentFailed}: $memo (code: $resultStatus)', isError: true);
      }

    } catch (e, stackTrace) {
      print('===== Error Caught =====');
      print('Error: $e');
      print('StackTrace: $stackTrace');
      print('========================');

      if (!mounted) return;

      _updatePaymentState(PaymentState.idle);
      _showSnackBar(L10n.of(context).orderCreateFailed, isError: true);
    }
  }

  /// App 从后台恢复时验证支付结果
  /// 这是 WidgetsBindingObserver 的核心回调
  Future<void> _verifyPaymentOnResume() async {
    final apiClient = context.read<PsygoApiClient>();
    final outTradeNo = _pendingOutTradeNo;

    if (outTradeNo == null) return;

    _updatePaymentState(PaymentState.verifying, message: '正在确认支付结果...');

    // 轮询验证（简化版，3次尝试）
    for (int i = 0; i < 3; i++) {
      await Future.delayed(const Duration(seconds: 2));

      if (!mounted) return;

      try {
        final order = await apiClient.getOrderStatus(outTradeNo);
        print('📊 [RESUME-POLL-${i + 1}] Order status: ${order.status}');

        if (order.status == 'paid') {
          // 支付成功
          await _onPaymentVerified(apiClient);
          return;
        } else if (order.status == 'closed') {
          // 订单关闭
          _updatePaymentState(PaymentState.idle);
          _showSnackBar('支付已取消');
          return;
        }
      } catch (e) {
        print('⚠️ [RESUME-POLL-${i + 1}] Query failed: $e');
      }
    }

    // 3次都没查到，提示用户稍后查看
    _updatePaymentState(PaymentState.idle);
    _showSnackBar('支付结果确认中，请稍后在钱包查看余额');
  }

  /// 处理支付成功
  Future<void> _handlePaymentSuccess(PsygoApiClient apiClient, String outTradeNo) async {
    _updatePaymentState(PaymentState.verifying, message: '正在确认支付结果...');

    // 轮询查询订单状态（3秒一次，最多10次）
    for (int i = 0; i < 10; i++) {
      await Future.delayed(const Duration(seconds: 3));

      if (!mounted) return;

      try {
        final order = await apiClient.getOrderStatus(outTradeNo);
        print('📊 [POLL-${i + 1}] Order status: ${order.status}');

        if (order.status == 'paid') {
          await _onPaymentVerified(apiClient);
          return;
        }
      } catch (e) {
        print('⚠️ [POLL-${i + 1}] Query failed: $e');
      }
    }

    // 30秒内未查询到支付成功
    print('⚠️ [TIMEOUT] Payment verification timeout');
    if (mounted) {
      _updatePaymentState(PaymentState.idle);
      _showSnackBar('支付结果确认中，请稍后在钱包查看余额');
      Navigator.of(context).pop(false);
    }
  }

  /// 处理支付处理中（8000状态）
  Future<void> _handlePaymentProcessing(PsygoApiClient apiClient, String outTradeNo) async {
    _updatePaymentState(PaymentState.verifying, message: '支付处理中，请稍候...');

    // 轮询查询（5秒一次，最多12次）
    for (int i = 0; i < 12; i++) {
      await Future.delayed(const Duration(seconds: 5));

      if (!mounted) return;

      try {
        final order = await apiClient.getOrderStatus(outTradeNo);
        print('📊 [POLL-8000-${i + 1}] Order status: ${order.status}');

        if (order.status == 'paid') {
          await _onPaymentVerified(apiClient);
          return;
        } else if (order.status == 'closed') {
          _updatePaymentState(PaymentState.idle);
          _showSnackBar('支付已取消');
          return;
        }
      } catch (e) {
        print('⚠️ [POLL-8000-${i + 1}] Query failed: $e');
      }
    }

    // 60秒超时
    print('⚠️ [TIMEOUT-8000] Processing timeout after 60s');
    if (mounted) {
      _updatePaymentState(PaymentState.idle);
      _showSnackBar('支付处理超时，请稍后在钱包查看余额');
    }
  }

  /// 支付验证成功的统一处理
  Future<void> _onPaymentVerified(PsygoApiClient apiClient) async {
    print('✅ [VERIFIED] Order confirmed as paid');

    // 刷新用户余额
    try {
      await apiClient.getUserInfo();
    } catch (e) {
      print('⚠️ Failed to refresh user info: $e');
    }

    if (mounted) {
      _updatePaymentState(PaymentState.success, message: '支付成功！');

      // 使用真实的订单数据，如果没有则使用默认计算值
      final amount = _realTotalAmount ?? widget.amount;
      final credits = _realCreditsAmount ?? (widget.amount * 100).round();

      // 跳转到充值成功页面
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => PaymentSuccessPage(
            amount: amount,
            credits: credits,
          ),
        ),
      );
    }
  }

  /// 显示 SnackBar 提示
  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);

    // 如果正在处理支付，显示全屏 loading 覆盖层
    final isProcessing = _paymentState != PaymentState.idle &&
                         _paymentState != PaymentState.success;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(
          color: Colors.black, // 返回按钮固定为黑色
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, size: 20, color: Colors.black),
          onPressed: isProcessing ? null : () => Navigator.of(context).pop(),
        ),
        title: Column(
          children: [
            Text(
              l10n.orderConfirmPayment,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 17,
                color: Colors.black, // 标题固定为黑色
              ),
            ),
            const SizedBox(height: 2),
            Text(
              l10n.orderSecureEnvironment,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[500],
              ),
            ),
          ],
        ),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          // 主内容
          Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 16),
                      // 订单信息卡片
                      _buildOrderCard(l10n),
                      const SizedBox(height: 16),
                      // 支付方式选择
                      _buildPaymentMethods(l10n),
                    ],
                  ),
                ),
              ),
              // 底部支付区域
              _buildBottomSection(l10n),
            ],
          ),

          // ========== 页面级 Loading 覆盖层（核心改动） ==========
          // 使用 Stack + 覆盖层替代 showDialog，解决生命周期问题
          if (isProcessing)
            Container(
              color: Colors.black.withValues(alpha: 0.5),
              child: Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 48),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_paymentState == PaymentState.success)
                        const Icon(
                          Icons.check_circle,
                          color: _primaryGreen,
                          size: 48,
                        )
                      else
                        const CircularProgressIndicator(color: _primaryGreen),
                      const SizedBox(height: 16),
                      Text(
                        _statusMessage.isNotEmpty
                            ? _statusMessage
                            : l10n.walletProcessing,
                        style: const TextStyle(fontSize: 16),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOrderCard(L10n l10n) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFE8F5E9),
            Color(0xFFC8E6C9),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _primaryGreen.withAlpha(25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部行：充值订单 + 倒计时
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.auto_awesome,
                    size: 18,
                    color: _primaryGreen,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    l10n.orderRechargeOrder,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.access_time,
                      size: 14,
                      color: Colors.grey[600],
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _countdownText,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[700],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),

          // 订单号
          Text(
            '${l10n.orderNumber}: $_orderNo',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 20),

          // 支付金额区域
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(8),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              children: [
                Text(
                  l10n.orderPayAmount,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        '¥',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: _primaryGreen,
                        ),
                      ),
                    ),
                    Text(
                      widget.amount.toStringAsFixed(0),
                      style: const TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        color: _primaryGreen,
                        height: 1,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: _lightGreen,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.check_circle,
                        size: 14,
                        color: _primaryGreen,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${l10n.orderWillGetCredits} ${(widget.amount * 100).toStringAsFixed(0)} ${l10n.walletCreditsUnit}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: _primaryGreen,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentMethods(L10n l10n) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Row(
            children: [
              Container(
                width: 4,
                height: 16,
                decoration: BoxDecoration(
                  color: _primaryGreen,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                l10n.orderSelectPayment,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 微信支付（暂不可用）
          // _buildPaymentOption(
          //   index: 0,
          //   icon: Icons.wechat,
          //   iconColor: const Color(0xFF07C160),
          //   title: l10n.walletWechatPay,
          //   subtitle: l10n.orderQuickPay,
          //   isRecommended: true,
          //   recommendedLabel: l10n.orderRecommended,
          // ),
          // const SizedBox(height: 12),

          // 支付宝
          _buildPaymentOption(
            index: 1,
            icon: Icons.account_balance_wallet,
            iconColor: const Color(0xFF1677FF),
            title: l10n.walletAlipay,
            subtitle: l10n.orderQuickPay,
            isRecommended: false,
          ),

          // 银行卡（暂不可用）
          // const SizedBox(height: 12),
          // _buildPaymentOption(
          //   index: 2,
          //   icon: Icons.credit_card,
          //   iconColor: const Color(0xFF666666),
          //   title: l10n.orderBankCard,
          //   subtitle: l10n.orderDebitCredit,
          //   isRecommended: false,
          // ),
        ],
      ),
    );
  }

  Widget _buildPaymentOption({
    required int index,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool isRecommended,
    String? recommendedLabel,
  }) {
    final isSelected = _selectedPayment == index;
    final isProcessing = _paymentState != PaymentState.idle;

    return GestureDetector(
      onTap: isProcessing ? null : () {
        setState(() {
          _selectedPayment = index;
        });
      },
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: isProcessing ? 0.5 : 1.0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isSelected ? _lightGreen.withAlpha(80) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected ? _primaryGreen : Colors.grey[200]!,
              width: isSelected ? 2 : 1,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: _primaryGreen.withAlpha(25),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              // 图标
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  color: iconColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),

              // 标题和副标题
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: Colors.black87,
                          ),
                        ),
                        if (isRecommended && recommendedLabel != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: _lightGreen,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              recommendedLabel,
                              style: const TextStyle(
                                fontSize: 10,
                                color: _primaryGreen,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ),

              // 单选按钮
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected ? _primaryGreen : Colors.grey[300]!,
                    width: 2,
                  ),
                ),
                child: isSelected
                    ? Center(
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: _primaryGreen,
                          ),
                        ),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomSection(L10n l10n) {
    final isProcessing = _paymentState != PaymentState.idle;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 确认支付按钮
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: isProcessing ? null : _onConfirmPayment,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primaryGreen,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey[300],
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.lock_rounded, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      l10n.orderConfirmPay,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 安全图标行
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildSecurityBadge(Icons.security, l10n.orderFundSafe),
                const SizedBox(width: 24),
                _buildSecurityBadge(Icons.flash_on, l10n.orderInstant),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSecurityBadge(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 14,
          color: Colors.grey[400],
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey[500],
          ),
        ),
      ],
    );
  }
}
