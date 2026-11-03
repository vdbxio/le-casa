// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart' hide Split;

import '../app.dart';
import '../dashboard/catalog.dart';
import '../dashboard/dashboard_page.dart' show cardContent;
import '../dashboard/layout.dart';
import '../ui/palette.dart';
import 'design_store.dart';
import 'sidebar.dart';

/// The four sizes every card comes in, at the size it is drawn in Design.
const designBreakpoints = <(CardSize, String, Size)>[
  (CardSize.large, 'Large', Size(440, 300)),
  (CardSize.medium, 'Medium', Size(320, 220)),
  (CardSize.small, 'Small', Size(240, 130)),
  (CardSize.pill, 'Pill', Size(240, 56)),
];

/// Which palette Design is editing, shared by the panel and the previews.
final ValueNotifier<Brightness?> _editing = ValueNotifier(null);

Brightness _editingOf(BuildContext context) =>
    _editing.value ?? Theme.of(context).brightness;

/// Settings › Design: colours, shape and spacing for the whole dashboard.
/// The panel holds the controls; common cards at each size show beside it
/// and the dashboard behind follows along.
class DesignPage extends StatefulWidget {
  const DesignPage({super.key});

  @override
  State<DesignPage> createState() => _DesignPageState();
}

class _DesignPageState extends State<DesignPage> {
  /// The colour whose picker is open.
  String? _open;

  @override
  void dispose() {
    _editing.value = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppServices.of(context);
    final design = s.design;
    return SidebarStage(
      stage: const DesignStage(),
      child: ListenableBuilder(
        listenable: Listenable.merge([design, _editing]),
        builder: (context, _) {
          final b = _editingOf(context);
          final colors = (b == Brightness.dark ? LeColors.dark : LeColors.light)
              .withOverrides(design.colorsFor(b));
          final st = design.style;
          return Scaffold(
            appBar: AppBar(
              title: const Text('Design'),
              actions: [
                TextButton(
                  onPressed: design.isStandard ? null : () => _reset(design),
                  child: const Text('Reset'),
                ),
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                const _Header('Colours'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: SegmentedButton<Brightness>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: Brightness.light,
                        icon: Icon(Icons.light_mode_outlined),
                        label: Text('Light'),
                      ),
                      ButtonSegment(
                        value: Brightness.dark,
                        icon: Icon(Icons.dark_mode_outlined),
                        label: Text('Dark'),
                      ),
                    ],
                    selected: {b},
                    onSelectionChanged: (v) => _editing.value = v.single,
                  ),
                ),
                for (final name in LeColors.editable)
                  _ColorRow(
                    name: name,
                    color: colors.named(name),
                    changed: design.colorsFor(b).containsKey(name),
                    open: _open == name,
                    onToggle: () =>
                        setState(() => _open = _open == name ? null : name),
                    onPick: (c) => design.setColor(b, name, c),
                  ),
                const _Header('Shape'),
                _Slider(
                  label: 'Corner radius',
                  value: st.radius,
                  min: 0,
                  max: 40,
                  onChanged: (v) => design.setStyle(st.copyWith(radius: v)),
                ),
                _Slider(
                  label: 'Border',
                  value: st.border,
                  min: 0,
                  max: 4,
                  divisions: 8,
                  decimals: 1,
                  onChanged: (v) => design.setStyle(st.copyWith(border: v)),
                ),
                const _Header('Spacing'),
                _Slider(
                  label: 'Padding inside cards',
                  value: st.padding,
                  min: 8,
                  max: 28,
                  onChanged: (v) => design.setStyle(st.copyWith(padding: v)),
                ),
                _Slider(
                  label: 'Gap between cards',
                  value: st.gap,
                  min: 0,
                  max: 32,
                  onChanged: (v) => design.setStyle(st.copyWith(gap: v)),
                ),
                _Slider(
                  label: 'Margin at the screen edge',
                  value: st.edge,
                  min: 0,
                  max: 40,
                  onChanged: (v) => design.setStyle(st.copyWith(edge: v)),
                ),
                const _Header('Text'),
                _Slider(
                  label: 'Card title size',
                  value: st.titleSize,
                  min: 12,
                  max: 20,
                  onChanged: (v) => design.setStyle(st.copyWith(titleSize: v)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _reset(DesignStore design) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Back to the standard look?'),
        content: const Text(
          'Colours for light and dark, shape and spacing all go back.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok == true) design.reset();
  }
}

const _colorNames = {
  'screen': ('Background', 'Behind the cards'),
  'card': ('Cards', 'The card itself'),
  'ink': ('Text', 'Numbers and titles'),
  'muted': ('Quiet text', 'Labels and units'),
  'line': ('Lines', 'Borders and dividers'),
  'accent': ('Accent', 'Edit tools, buttons and highlights'),
};

class _ColorRow extends StatelessWidget {
  final String name;
  final Color color;
  final bool changed, open;
  final VoidCallback onToggle;
  final ValueChanged<Color?> onPick;

  const _ColorRow({
    required this.name,
    required this.color,
    required this.changed,
    required this.open,
    required this.onToggle,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final (title, hint) = _colorNames[name] ?? (name, '');
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        ListTile(
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.outline),
            ),
          ),
          title: Text(title),
          subtitle: Text(
            changed ? '$hint · ${_hex(color)}' : hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (changed)
                IconButton(
                  tooltip: 'Standard colour',
                  icon: const Icon(Icons.restart_alt),
                  onPressed: () => onPick(null),
                ),
              Icon(open ? Icons.expand_less : Icons.expand_more),
            ],
          ),
          onTap: onToggle,
        ),
        if (open) _Picker(color: color, onPick: onPick),
      ],
    );
  }
}

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// Swatches to start from, then hue, saturation and lightness.
class _Picker extends StatelessWidget {
  final Color color;
  final ValueChanged<Color?> onPick;
  const _Picker({required this.color, required this.onPick});

  static const _swatches = [
    Color(0xFFFFFFFF),
    Color(0xFFF2F5F2),
    Color(0xFFF4EFE6),
    Color(0xFFC6CFC9),
    Color(0xFF5A6962),
    Color(0xFF16201B),
    Color(0xFF090D0B),
    Color(0xFF1D2622),
    Color(0xFF3A50D9),
    Color(0xFF8F9EFF),
    Color(0xFF188A55),
    Color(0xFF2678A8),
    Color(0xFFCC5023),
    Color(0xFFB87D00),
    Color(0xFFC2185B),
    Color(0xFF7B1FA2),
  ];

  @override
  Widget build(BuildContext context) {
    final hsl = HSLColor.fromColor(color);
    Widget slider(
      String label,
      double v,
      double max,
      HSLColor Function(double) f,
    ) => Row(
      children: [
        SizedBox(
          width: 86,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: Slider(
            value: v.clamp(0, max),
            max: max,
            onChanged: (x) => onPick(f(x).toColor()),
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 12),
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in _swatches)
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => onPick(c),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: c.toARGB32() == color.toARGB32()
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outlineVariant,
                        width: c.toARGB32() == color.toARGB32() ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          slider('Hue', hsl.hue, 360, hsl.withHue),
          slider('Saturation', hsl.saturation, 1, hsl.withSaturation),
          slider('Lightness', hsl.lightness, 1, hsl.withLightness),
        ],
      ),
    );
  }
}

class _Slider extends StatelessWidget {
  final String label;
  final double value, min, max;
  final int? divisions;
  final int decimals;
  final ValueChanged<double> onChanged;

  const _Slider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    this.decimals = 0,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
    child: Row(
      children: [
        Expanded(flex: 4, child: Text(label)),
        Expanded(
          flex: 6,
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions ?? (max - min).round(),
            label: value.toStringAsFixed(decimals),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            value.toStringAsFixed(decimals),
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

/// Common cards at every size, drawn in the look being edited, on the
/// dimmed dashboard beside the Design panel.
class DesignStage extends StatelessWidget {
  const DesignStage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppServices.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.design, s.liveData, _editing]),
      builder: (context, _) {
        final b = _editingOf(context);
        final sources = CardSources(
          tracker: s.tracker,
          history: s.history,
          tablet: s.tablet,
          weather: s.weather,
          heardBefore: (id) => s.dashboard.heard[id],
        );
        final specs = designSamples(s, sources);
        return Theme(
          data: s.design.theme(b),
          child: Builder(
            builder: (context) {
              final c = LeColors.of(context);
              final look = CardStyle.of(context);
              return Container(
                margin: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: c.screen,
                  borderRadius: BorderRadius.circular(24),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListView(
                  padding: EdgeInsets.all(look.edge + 6),
                  children: [
                    for (final spec in specs) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8, left: 2),
                        child: Text(
                          spec.type == 'clock'
                              ? 'Clock'
                              : sources.model(spec).title,
                          style: TextStyle(
                            color: c.muted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Wrap(
                        spacing: look.gap,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.end,
                        children: [
                          for (final (size, label, box) in designBreakpoints)
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox.fromSize(
                                  size: box,
                                  child: cardContent(
                                    spec.copyWith(pinned: size),
                                    box,
                                    sources,
                                    extraPadding: look.extraPadding,
                                  ).$1,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '$label · ${box.width.toInt()}×${box.height.toInt()}',
                                  style: TextStyle(
                                    color: c.muted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                      SizedBox(height: look.gap + 14),
                    ],
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// The cards Design shows: the clock, then what is on the dashboard (or
/// heard nearby when it is still empty), a few of each kind.
List<CardSpec> designSamples(AppServices s, CardSources sources) {
  final out = <CardSpec>[const CardSpec('clock')];
  final seen = <String>{'clock'};
  final dash = s.dashboard;
  final fromDash = !dash.hasLayout
      ? const <CardSpec>[]
      : [
          for (final (_, slot) in dash.page.slots)
            if (slot.card case final c? when c.type != 'chips') c,
        ];
  for (final c in [...fromDash, for (final e in catalog(sources)) e.spec]) {
    if (out.length >= 5) break;
    if (!seen.add(c.key)) continue;
    out.add(c);
  }
  return out;
}
