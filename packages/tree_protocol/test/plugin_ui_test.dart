// Q12 插件布局协议测试：三类帧 + 视图模型的编解码往返、宽容解析与常量登记。
//
// 运行方式（packages/tree_protocol 目录）：
//   dart test test/plugin_ui_test.dart
import 'package:test/test.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 一份"核心侧会发出来的"完整 manifest 帧（字段齐全，便于无损往返断言）。
Map<String, dynamic> _manifestFrame() => <String, dynamic>{
      'type': 'plugin_ui_manifest',
      'data': <String, dynamic>{
        'plugin_id': 'demo.plugin',
        'team_id': 'team_1',
        'slots': <dynamic>[
          <String, dynamic>{
            'slot_key': 'demo.plugin.activity.1',
            'slot': 'activity',
            'plugin_id': 'demo.plugin',
            'team_id': 'team_1',
            'title': '演示插件',
            'icon': 'extension',
            'order': 10,
            'view': <String, dynamic>{
              'type': 'text',
              'text': '**活动栏**内容',
              'format': 'markdown',
            },
          },
          <String, dynamic>{
            'slot_key': 'demo.plugin.panel.1',
            'slot': 'panel',
            'plugin_id': 'demo.plugin',
            'team_id': 'team_1',
            'title': '演示面板',
            'order': 0,
            'view': <dynamic>[
              <String, dynamic>{
                'type': 'table',
                'columns': <dynamic>['列 A', '列 B'],
                'rows': <dynamic>[
                  <dynamic>['1', '2'],
                  <dynamic>['3', '4'],
                ],
              },
              <String, dynamic>{
                'type': 'actions',
                'buttons': <dynamic>[
                  <String, dynamic>{'action_id': 'refresh', 'label': '刷新'},
                ],
              },
            ],
          },
        ],
      },
    };

/// 一份完整的 update 帧（整块替换）。
Map<String, dynamic> _updateFrame() => <String, dynamic>{
      'type': 'plugin_ui_update',
      'data': <String, dynamic>{
        'plugin_id': 'demo.plugin',
        'team_id': 'team_1',
        'slot_key': 'demo.plugin.status.1',
        'view': <String, dynamic>{
          'type': 'progress',
          'value': 0.42,
          'label': '同步中',
          'detail': '42%',
        },
      },
    };

/// 一份完整的 action 帧（前端 → 核心）。
Map<String, dynamic> _actionFrame() => <String, dynamic>{
      'type': 'plugin_ui_action',
      'data': <String, dynamic>{
        'plugin_id': 'demo.plugin',
        'team_id': 'team_1',
        'agent_id': 'agent_1',
        'session_id': 'session_default',
        'slot_key': 'demo.plugin.panel.1',
        'action_id': 'save',
        'payload': <String, dynamic>{'name': 'x'},
      },
    };

void main() {
  group('三类帧编解码往返', () {
    test('manifest：解码 → 编码与原始帧逐字段相等', () {
      final Map<String, dynamic> frame = _manifestFrame();
      final PluginUiManifest? manifest = PluginUiManifest.fromFrame(frame);
      expect(manifest, isNotNull);
      expect(manifest!.pluginId, 'demo.plugin');
      expect(manifest.teamId, 'team_1');
      expect(manifest.slots, hasLength(2));
      expect(manifest.slots.first.kind, PluginUiSlotKind.activity);
      expect(manifest.slots.first.title, '演示插件');
      expect(manifest.slots.first.order, 10);
      expect(manifest.toFrame(), frame);
    });

    test('manifest：槽位缺 plugin_id / team_id 时回落到帧级字段', () {
      final Map<String, dynamic> frame = <String, dynamic>{
        'type': PluginUiFrameType.manifest,
        'data': <String, dynamic>{
          'plugin_id': 'demo.plugin',
          'team_id': 'team_9',
          'slots': <dynamic>[
            <String, dynamic>{
              'slot_key': 'k1',
              'slot': 'status',
              'view': <String, dynamic>{'type': 'text', 'text': 'ok'},
            },
          ],
        },
      };
      final PluginUiManifest manifest = PluginUiManifest.fromFrame(frame)!;
      expect(manifest.slots.single.pluginId, 'demo.plugin');
      expect(manifest.slots.single.teamId, 'team_9');
    });

    test('update：解码 → 编码与原始帧逐字段相等', () {
      final Map<String, dynamic> frame = _updateFrame();
      final PluginUiUpdate? update = PluginUiUpdate.fromFrame(frame);
      expect(update, isNotNull);
      expect(update!.slotKey, 'demo.plugin.status.1');
      expect(update.view!.nodes.single.type, PluginUiViewType.progress);
      expect(update.view!.nodes.single.numOrNull('value'), 0.42);
      expect(update.toFrame(), frame);
    });

    test('update：view 显式 null ⇒ 注销该槽位（view == null）', () {
      final PluginUiUpdate? update = PluginUiUpdate.fromFrame(<String, dynamic>{
        'type': PluginUiFrameType.update,
        'data': <String, dynamic>{'slot_key': 'k1', 'view': null},
      });
      expect(update, isNotNull);
      expect(update!.view, isNull);
      // 显式 null 编码后仍是 null（不是缺键），语义不丢
      expect(update.toJson()['view'], isNull);
    });

    test('action：解码 → 编码与原始帧逐字段相等', () {
      final Map<String, dynamic> frame = _actionFrame();
      final PluginUiAction? action = PluginUiAction.fromFrame(frame);
      expect(action, isNotNull);
      expect(action!.slotKey, 'demo.plugin.panel.1');
      expect(action.actionId, 'save');
      expect(action.payload, <String, dynamic>{'name': 'x'});
      expect(action.toFrame(), frame);
    });

    test('帧类型不匹配时 fromFrame 返回 null（不误吞别的帧）', () {
      final Map<String, dynamic> other = <String, dynamic>{
        'type': WsOutboundType.pluginStatus,
        'data': <String, dynamic>{},
      };
      expect(PluginUiManifest.fromFrame(other), isNull);
      expect(PluginUiUpdate.fromFrame(other), isNull);
      expect(PluginUiAction.fromFrame(other), isNull);
    });
  });

  group('视图模型编解码', () {
    test('view 单节点形态与数组形态均无损往返', () {
      final Map<String, dynamic> single = <String, dynamic>{
        'type': 'text',
        'text': 'hi',
      };
      final PluginUiView one = PluginUiView.tryParse(single)!;
      expect(one.isArray, isFalse);
      expect(one.nodes, hasLength(1));
      expect(one.toJson(), single);

      final List<dynamic> many = <dynamic>[
        <String, dynamic>{'type': 'text', 'text': 'a'},
        <String, dynamic>{'type': 'progress', 'value': 0.5},
      ];
      final PluginUiView list = PluginUiView.tryParse(many)!;
      expect(list.isArray, isTrue);
      expect(list.nodes, hasLength(2));
      expect(list.toJson(), many);
    });

    test('容器 children 与嵌套控件解析', () {
      final PluginUiView view = PluginUiView.tryParse(<String, dynamic>{
        'type': 'column',
        'gap': 8,
        'children': <dynamic>[
          <String, dynamic>{'type': 'text', 'text': '上半'},
          <String, dynamic>{
            'type': 'row',
            'children': <dynamic>[
              <String, dynamic>{'type': 'text', 'text': '左'},
              <String, dynamic>{'type': 'text', 'text': '右'},
            ],
          },
        ],
      })!;
      final PluginUiNode column = view.nodes.single;
      expect(column.type, PluginUiViewType.column);
      expect(column.numOrNull('gap'), 8);
      expect(column.children, hasLength(2));
      expect(column.children.last.children, hasLength(2));
      expect(column.isKnownType, isTrue);
    });

    test('表单字段：类型/标签/候选项/初始值/必填', () {
      final PluginUiNode form = PluginUiView.tryParse(<String, dynamic>{
        'type': 'form',
        'fields': <dynamic>[
          <String, dynamic>{
            'key': 'name',
            'label': '名称',
            'kind': 'textarea',
            'value': '初值',
            'required': true,
            'placeholder': '请输入',
            'help': '说明',
          },
          <String, dynamic>{
            'key': 'level',
            'kind': 'select',
            'options': <dynamic>['a', 2],
          },
          // 坏字段（缺 key）应被跳过
          <String, dynamic>{'label': '无 key'},
        ],
        'submit': <String, dynamic>{'action_id': 'save', 'label': '保存'},
      })!.nodes.single;

      final List<PluginUiField> fields = <PluginUiField>[];
      for (final Object? item in form.listOrEmpty('fields')) {
        final PluginUiField? field = PluginUiField.tryParse(item);
        if (field != null) {
          fields.add(field);
        }
      }
      expect(fields, hasLength(2), reason: '缺 key 的字段必须被跳过');
      expect(fields.first.key, 'name');
      expect(fields.first.label, '名称');
      expect(fields.first.kind, PluginUiFieldKind.textarea);
      expect(fields.first.value, '初值');
      expect(fields.first.required, isTrue);
      expect(fields.last.kind, PluginUiFieldKind.select);
      expect(fields.last.options, <String>['a', '2']);
      expect(fields.last.label, 'level', reason: '缺 label 时回退 key');
    });

    test('按钮：样式回退 / enabled 缺省 / payload 缺省', () {
      final PluginUiNode actions = PluginUiView.tryParse(<String, dynamic>{
        'type': 'actions',
        'buttons': <dynamic>[
          <String, dynamic>{'action_id': 'a', 'label': 'A', 'style': 'danger'},
          <String, dynamic>{'action_id': 'b', 'enabled': false},
          <String, dynamic>{'label': '无 id'},
        ],
      })!.nodes.single;

      final List<PluginUiButton> buttons = <PluginUiButton>[];
      for (final Object? item in actions.listOrEmpty('buttons')) {
        final PluginUiButton? button = PluginUiButton.tryParse(item);
        if (button != null) {
          buttons.add(button);
        }
      }
      expect(buttons, hasLength(2));
      expect(buttons.first.style, PluginUiButtonStyle.danger);
      expect(buttons.last.label, 'b', reason: '缺 label 时回退 action_id');
      expect(buttons.last.style, PluginUiButtonStyle.secondary);
      expect(buttons.last.enabled, isFalse);
      expect(buttons.last.payload, isEmpty);
    });

    test('宽容解析：坏槽位跳过、未知控件类型原样保留、非 Map 视图返回 null', () {
      final PluginUiManifest manifest =
          PluginUiManifest.fromFrame(<String, dynamic>{
        'type': PluginUiFrameType.manifest,
        'data': <String, dynamic>{
          'plugin_id': 'demo.plugin',
          'team_id': 'team_1',
          'slots': <dynamic>[
            <String, dynamic>{'slot_key': '', 'slot': 'activity'},
            <String, dynamic>{'slot_key': 'k', 'slot': 'unknown_kind'},
            'not-a-map',
            <String, dynamic>{
              'slot_key': 'demo.plugin.card.1',
              'slot': 'card',
              'view': <String, dynamic>{'type': 'holo_deck', 'x': 1},
            },
          ],
        },
      })!;
      expect(manifest.slots, hasLength(1));
      final PluginUiNode node = manifest.slots.single.view.nodes.single;
      expect(node.type, 'holo_deck');
      expect(node.isKnownType, isFalse, reason: '未知类型交由渲染器占位');
      expect(node.toJson(), <String, dynamic>{'type': 'holo_deck', 'x': 1});
      expect(PluginUiView.tryParse('nope'), isNull);
    });
  });

  group('常量登记（完备性）', () {
    test('三类帧 + 方向集合', () {
      expect(PluginUiFrameType.all, <String>{
        'plugin_ui_manifest',
        'plugin_ui_update',
        'plugin_ui_action',
      });
      expect(PluginUiFrameType.outbound, <String>{
        PluginUiFrameType.manifest,
        PluginUiFrameType.update,
      });
      expect(PluginUiFrameType.inbound, <String>{PluginUiFrameType.action});
      // 上行/下行不重叠，且都不与既有帧类型重名（除 heartbeat 的既有例外）
      expect(
        PluginUiFrameType.outbound.intersection(PluginUiFrameType.inbound),
        isEmpty,
      );
      // action 以**别名**登记进 WsInboundType.all（值相同、不重复字面量），
      // 所以交集恰好是它一个；manifest / update 仍是全新的下行类型。
      expect(
        PluginUiFrameType.all.intersection(<String>{
          ...WsOutboundType.all,
          ...WsInboundType.all,
        }),
        <String>{PluginUiFrameType.action},
        reason: '三件套必须是与既有帧不同的新类型；action 例外（别名登记）',
      );
      expect(WsInboundType.pluginUiAction, PluginUiFrameType.action);
      expect(WsInboundType.all, contains(PluginUiFrameType.action));
    });

    test('四类槽位 / 六种控件 / 容器 / 字段 / 按钮样式', () {
      expect(PluginUiSlotKind.all, <String>{
        PluginUiSlotKind.activity,
        PluginUiSlotKind.panel,
        PluginUiSlotKind.status,
        PluginUiSlotKind.card,
      });
      expect(PluginUiViewType.controls, <String>{
        PluginUiViewType.text,
        PluginUiViewType.list,
        PluginUiViewType.table,
        PluginUiViewType.form,
        PluginUiViewType.progress,
        PluginUiViewType.actions,
      });
      expect(PluginUiViewType.containers, <String>{
        PluginUiViewType.row,
        PluginUiViewType.column,
      });
      expect(
        PluginUiViewType.controls.intersection(PluginUiViewType.containers),
        isEmpty,
      );
      expect(
        PluginUiViewType.all,
        PluginUiViewType.controls.union(PluginUiViewType.containers),
      );
      expect(PluginUiFieldKind.all, hasLength(5));
      expect(PluginUiButtonStyle.all, hasLength(3));
    });
  });
}
