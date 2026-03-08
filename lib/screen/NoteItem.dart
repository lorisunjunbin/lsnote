import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../i18n/SimpleLocalizations.dart';
import '../model/Note.dart';
import '../service/NoteAccessSqlite.dart';
import '../utils/NavigationHelper.dart';
import 'NoteLanding.dart';

class NoteItem extends StatefulWidget {
  static final String routeName = '/NoteItem';

  @override
  _NoteItemState createState() => _NoteItemState();
}

class _NoteItemState extends State<NoteItem>
    with SingleTickerProviderStateMixin {
  static DateTime _datetime = DateTime.now().add(const Duration(days: 1));
  late final TextEditingController _titleCtl;
  late final TextEditingController _contentCtl;
  late final AnimationController _animationController;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _titleCtl = TextEditingController();
    _contentCtl = TextEditingController();

    // 页面进入动画
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    SchedulerBinding.instance.addPostFrameCallback((_) {
      _animationController.forward();
    });
  }

  @override
  void dispose() {
    _contentCtl.dispose();
    _titleCtl.dispose();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final sl = SimpleLocalizations.of(context)!;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: NavigationHelper.createPopCallback(
        context,
        NoteLanding.routeName,
      ),
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: _buildAppBar(context, sl, colorScheme),
        body: FadeTransition(
          opacity: _fadeAnimation,
          child: SlideTransition(
            position: _slideAnimation,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionTitle(sl, 'targetDate', 'Target Date'),
                  const SizedBox(height: 12),
                  _buildDatepickerCard(colorScheme, sl),
                  const SizedBox(height: 28),
                  _buildSectionTitle(sl, 'titleLabel', 'Title'),
                  const SizedBox(height: 12),
                  _buildNoteTitleTextField(colorScheme, sl),
                  const SizedBox(height: 24),
                  _buildSectionTitle(sl, 'contentLabel', 'Content'),
                  const SizedBox(height: 12),
                  _buildNoteDetailTextField(colorScheme, sl),
                  const SizedBox(height: 40),
                  _buildSaveButton(colorScheme, sl),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Material 3 AppBar
  PreferredSizeWidget _buildAppBar(
      BuildContext context, SimpleLocalizations sl, ColorScheme colorScheme) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: () => NavigationHelper.replaceTo(
          context,
          NoteLanding.routeName,
        ),
      ),
      elevation: 0,
      scrolledUnderElevation: 1,
      title: Text(
        sl.getText('addNote') ?? 'New Note',
        style: TextStyle(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 区块标题
  Widget _buildSectionTitle(SimpleLocalizations sl, String key, String fallback) {
    final colorScheme = Theme.of(context).colorScheme;
    return Text(
      sl.getText(key) ?? fallback,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: colorScheme.primary,
        letterSpacing: 0.5,
      ),
    );
  }

  /// Material 3 日期选择器卡片
  Widget _buildDatepickerCard(ColorScheme colorScheme, SimpleLocalizations sl) {
    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showDatePicker(sl, colorScheme),
        child: Container(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.calendar_month_rounded,
                  color: colorScheme.onPrimaryContainer,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sl.getText('targetDate') ?? 'Target Date',
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _formatDate(_datetime),
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: colorScheme.onSurfaceVariant,
                size: 24,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 显示日期选择器
  void _showDatePicker(SimpleLocalizations sl, ColorScheme colorScheme) {
    showDatePicker(
      context: context,
      initialDate: _datetime,
      firstDate: DateTime.parse("2020-01-01"),
      lastDate: DateTime.parse("2030-12-31"),
      cancelText: sl.getText('cancelLabel'),
      confirmText: sl.getText('confirmLabel'),
      helpText: sl.getText('targetDate') ?? 'Select Date',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: colorScheme,
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.primary,
              ),
            ),
          ),
          child: child!,
        );
      },
    ).then((value) {
      if (value != null) {
        setState(() {
          _datetime = value;
        });
      }
    });
  }

  /// 格式化日期显示
  String _formatDate(DateTime date) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  /// Material 3 标题输入框
  Widget _buildNoteTitleTextField(ColorScheme colorScheme, SimpleLocalizations sl) {
    return TextField(
      controller: _titleCtl,
      keyboardType: TextInputType.text,
      textCapitalization: TextCapitalization.sentences,
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
      decoration: InputDecoration(
        hintText: sl.getText('titleLabel') ?? 'Title',
        hintStyle: TextStyle(
          color: colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w400,
        ),
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: colorScheme.primary,
            width: 2,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: colorScheme.error,
            width: 2,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 18,
        ),
      ),
    );
  }

  /// Material 3 内容输入框
  Widget _buildNoteDetailTextField(ColorScheme colorScheme, SimpleLocalizations sl) {
    return TextField(
      controller: _contentCtl,
      keyboardType: TextInputType.multiline,
      maxLines: null,
      minLines: 8,
      textCapitalization: TextCapitalization.sentences,
      style: TextStyle(
        fontSize: 16,
        height: 1.5,
        color: colorScheme.onSurface,
      ),
      decoration: InputDecoration(
        hintText: sl.getText('contentLabel') ?? 'Content',
        hintStyle: TextStyle(
          color: colorScheme.onSurfaceVariant,
        ),
        alignLabelWithHint: true,
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: colorScheme.primary,
            width: 2,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 16,
        ),
      ),
    );
  }

  /// Material 3 保存按钮
  Widget _buildSaveButton(ColorScheme colorScheme, SimpleLocalizations sl) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton.icon(
        icon: const Icon(Icons.save_rounded, size: 24),
        label: Text(
          sl.getText('saveLabel') ?? 'Save',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        onPressed: () => _handleSave(sl, colorScheme),
      ),
    );
  }

  /// 处理保存操作
  void _handleSave(SimpleLocalizations sl, ColorScheme colorScheme) async {
    if (_titleCtl.value.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.error_outline_rounded, color: colorScheme.onPrimaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  sl.getText('titleRequired') ?? 'Title is required',
                  style: TextStyle(color: colorScheme.onPrimaryContainer),
                ),
              ),
            ],
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          backgroundColor: colorScheme.primaryContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      );
      return;
    }

    // 添加保存反馈动画
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.onPrimaryContainer),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'Saving...',
              style: TextStyle(color: colorScheme.onPrimaryContainer),
            ),
          ],
        ),
        duration: const Duration(milliseconds: 800),
        behavior: SnackBarBehavior.floating,
        backgroundColor: colorScheme.primaryContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    );

    // 保存笔记
    int total = await db.getNoteCount();
    await db.addNote(Note(
      title: _titleCtl.value.text,
      content: _contentCtl.value.text,
      sequence: total * -NoteAccessSqlite.sequenceStep,
      isDone: false,
      targetDate: _datetime,
    ));

    // 延迟一下让用户看到保存成功反馈
    await Future.delayed(const Duration(milliseconds: 300));
    NavigationHelper.replaceTo(context, NoteLanding.routeName);

    setState(() {
      _datetime = DateTime.now().add(const Duration(days: 1));
    });
  }
}
