// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

import '../app.dart';
import '../platform/form_factor.dart';
import '../ui/devices_page.dart';
import '../ui/palette.dart';
import 'design_page.dart';
import 'home_page.dart';
import 'people.dart';
import 'settings_page.dart';

/// Opens settings: a panel down the right of the screen over the dimmed
/// dashboard. Its pages open inside the panel the way they would on a
/// phone. A page can show something large on the dimmed dashboard beside
/// the panel (a device's card, the design previews) with [SidebarStage].
Future<void> openSettings(BuildContext context) =>
    Navigator.of(context).push(_SettingsRoute());

/// Closes settings from any page inside it.
void closeSettings(BuildContext context) {
  final scope = context.getInheritedWidgetOfExactType<_SidebarScope>()?.state;
  if (scope != null) {
    scope.close();
  } else {
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
  }
}

/// How wide the panel is on a screen [width] wide. A phone gets all of it.
double sidebarWidth(Size screen) =>
    isPhoneSize(screen) ? screen.width : (screen.width * 0.42).clamp(340, 420);

class _SettingsRoute extends PageRoute<void> {
  _SettingsRoute();

  @override
  bool get opaque => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 240);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => _SettingsOverlay(animation: animation);
}

class _SettingsOverlay extends StatefulWidget {
  final Animation<double> animation;
  const _SettingsOverlay({required this.animation});

  @override
  State<_SettingsOverlay> createState() => _SettingsOverlayState();
}

class _SettingsOverlayState extends State<_SettingsOverlay> {
  final _nav = GlobalKey<NavigatorState>();

  /// What pages want to show beside the panel, the page on top last.
  final _stages = <(Object, Widget)>[];

  /// On a phone the panel covers the screen: the stage shows in its place
  /// while this is on.
  bool _phoneStage = false;
  bool _closing = false;

  void close() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  void _setStage(Object owner, Widget? stage) {
    void apply() {
      if (!mounted) return;
      setState(() {
        final i = _stages.indexWhere((e) => e.$1 == owner);
        if (stage == null) {
          if (i >= 0) _stages.removeAt(i);
          if (_stages.isEmpty) _phoneStage = false;
        } else if (i >= 0) {
          _stages[i] = (owner, stage);
        } else {
          _stages.add((owner, stage));
        }
      });
    }

    // Pages register while they build or unmount, when setState is not
    // allowed.
    WidgetsBinding.instance.addPostFrameCallback((_) => apply());
  }

  Future<void> _back() async {
    final nav = _nav.currentState;
    if (nav != null && await nav.maybePop()) return;
    close();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final phone = isPhoneSize(screen);
    final width = sidebarWidth(screen);
    final stage = _stages.lastOrNull?.$2;
    final a = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final panel = DecoratedBox(
      decoration: const BoxDecoration(
        boxShadow: [BoxShadow(color: Color(0x40000000), blurRadius: 24)],
      ),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: HeroControllerScope.none(
          child: Navigator(
            key: _nav,
            onGenerateRoute: (_) =>
                MaterialPageRoute<void>(builder: (_) => const SettingsMenu()),
          ),
        ),
      ),
    );
    return _SidebarScope(
      state: this,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _back();
        },
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(
                child: FadeTransition(
                  opacity: a,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // With a card showing, a stray tap beside it should not
                    // throw away what is open.
                    onTap: stage == null ? close : null,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ),
              if (stage != null && !phone)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  right: width,
                  child: FadeTransition(
                    opacity: a,
                    child: SafeArea(right: false, child: stage),
                  ),
                ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: width,
                child: SlideTransition(
                  position: Tween(
                    begin: const Offset(1, 0),
                    end: Offset.zero,
                  ).animate(a),
                  child: panel,
                ),
              ),
              if (stage != null && phone && _phoneStage)
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.85),
                    child: SafeArea(child: stage),
                  ),
                ),
              if (stage != null && phone)
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: SafeArea(
                    child: FloatingActionButton.extended(
                      heroTag: null,
                      onPressed: () =>
                          setState(() => _phoneStage = !_phoneStage),
                      icon: Icon(
                        _phoneStage ? Icons.tune : Icons.visibility_outlined,
                      ),
                      label: Text(_phoneStage ? 'Settings' : 'Preview'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarScope extends InheritedWidget {
  final _SettingsOverlayState state;
  const _SidebarScope({required this.state, required super.child});

  @override
  bool updateShouldNotify(_SidebarScope old) => false;
}

/// Shows [stage] on the dimmed dashboard beside the panel for as long as
/// [child], a page in the panel, is open. On a phone a Preview button
/// shows it in place of the panel.
class SidebarStage extends StatefulWidget {
  final Widget stage;
  final Widget child;
  const SidebarStage({super.key, required this.stage, required this.child});

  @override
  State<SidebarStage> createState() => _SidebarStageState();
}

class _SidebarStageState extends State<SidebarStage> {
  _SettingsOverlayState? _overlay;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final o = context.getInheritedWidgetOfExactType<_SidebarScope>()?.state;
    if (o != _overlay) {
      _overlay?._setStage(this, null);
      _overlay = o?.._setStage(this, widget.stage);
    }
  }

  @override
  void didUpdateWidget(SidebarStage old) {
    super.didUpdateWidget(old);
    if (old.stage != widget.stage) _overlay?._setStage(this, widget.stage);
  }

  @override
  void dispose() {
    _overlay?._setStage(this, null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The first page of the panel: the four sections, then the state of
/// things at a glance.
class SettingsMenu extends StatelessWidget {
  const SettingsMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppServices.of(context);
    final theme = Theme.of(context);
    void open(Widget page) =>
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => page));
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Settings'),
        actions: [
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => closeSettings(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          s.liveData,
          s.dashboard,
          s.home,
          s.sync,
          s.people,
          s.design,
          s.connections,
        ]),
        builder: (context, _) {
          final people = s.people.people;
          final atHome = [
            for (final p in people)
              if (personHome(p, s) == true) p,
          ];
          final heard = s.tracker.devices.where((d) => d.view != null).length;
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _Section(
                icon: Icons.tune,
                title: 'General',
                subtitle: 'Display, voice, Bluetooth and the dashboard',
                onTap: () => open(const SettingsPage()),
              ),
              _Section(
                icon: Icons.home_outlined,
                title: 'Home',
                subtitle: !s.home.inHome
                    ? 'People, screens and phones'
                    : people.isEmpty
                    ? '${s.home.homeName} · screens, phones and people'
                    : '${s.home.homeName} · ${atHome.length} of '
                          '${people.length} home',
                onTap: () => open(const HomeSettingsPage()),
              ),
              _Section(
                icon: Icons.devices_other,
                title: 'Devices',
                subtitle: '$heard recognised nearby',
                onTap: () => open(const DevicesPage()),
              ),
              _Section(
                icon: Icons.palette_outlined,
                title: 'Design',
                subtitle: s.design.isStandard
                    ? 'Colours, shape and spacing of cards'
                    : 'Your own look · colours, shape and spacing',
                onTap: () => open(const DesignPage()),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                child: Text(
                  'At a glance',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _Stats(atHome: atHome.length),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  const _Section({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: scheme.secondaryContainer,
        foregroundColor: scheme.onSecondaryContainer,
        child: Icon(icon),
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _Stats extends StatelessWidget {
  final int atHome;
  const _Stats({required this.atHome});

  @override
  Widget build(BuildContext context) {
    final s = AppServices.of(context);
    final dash = s.dashboard;
    final cards = dash.hasLayout ? dash.page.cardKeys.length : 0;
    final empty = dash.hasLayout
        ? dash.page.slots.where((e) => e.$2.card == null).length
        : 0;
    final unknown = s.tracker.unknown.length;
    final recognised = s.tracker.devices.length - unknown;
    final scanner = s.scanner;
    final busy = s.connections.busyId;
    final busyName = busy == null ? null : s.tracker[busy]?.latest.name;
    final screens = s.home.inHome ? s.sync.screens.length : 1;
    final stats = <(String, String, String?)>[
      ('Devices', '$recognised', unknown == 0 ? null : '+ $unknown unknown'),
      (
        'On the dashboard',
        '$cards',
        empty == 0 ? 'cards' : 'cards · $empty empty',
      ),
      (
        'Bluetooth',
        scanner.paused
            ? 'Paused'
            : scanner.scanning
            ? 'Scanning'
            : 'Waiting',
        '${s.tracker.totalPackets} packets',
      ),
      (
        'Connections',
        !s.connections.enabled
            ? 'Paused'
            : busy == null
            ? 'Idle'
            : 'Reading',
        busyName,
      ),
      (
        'Screens',
        '$screens',
        s.home.inHome
            ? (s.sync.inTouch ? 'linked' : 'looking for others')
            : 'not in a home',
      ),
      if (s.people.people.isNotEmpty)
        ('People home', '$atHome', 'of ${s.people.people.length}'),
      ('This screen', s.home.me.name, null),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final w = (box.maxWidth - 8) / 2;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final st in stats) _Stat(st, width: w)],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  final (String, String, String?) stat;
  final double width;
  const _Stat(this.stat, {required this.width});

  @override
  Widget build(BuildContext context) {
    final c = LeColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (label, value, note) = stat;
    return Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: c.muted)),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: numberStyle(22, c.ink),
          ),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(
              note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: c.muted),
            ),
          ],
        ],
      ),
    );
  }
}
