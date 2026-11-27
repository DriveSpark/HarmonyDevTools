const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(path.join(process.env.DEVECO_HOME || 'C:/Program Files/Huawei/DevEco Studio',
  'tools/hvigor/hvigor/node_modules/typescript'));

const file = path.join(__dirname, '../devtools/src/main/ets/DevToolsDeveloperSettings.ets');
const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
const developer = 'developer_options_settings';
const system = 'system_and_updates';
const unreadable = '无法读取开发者选项状态';
const failed = '未能打开开发者选项';
const retry = '打开开发者选项';
const parent = '前往系统';

function device(value, options = {}) {
  const events = [];
  const dialogs = [];
  const kit = {
    '@kit.BasicServicesKit': { deviceInfo: { productModel: options.model ?? 'phone' },
      settings: { general: { DEVELOPMENT_SETTINGS_STATUS: 'mode' },
      getValueSync: (_context, key, fallback) => {
        assert.equal(key, 'mode');
        assert.equal(fallback, '');
        if (value instanceof Error) throw value;
        return value;
      } } },
    '@kit.AbilityKit': { wantConstant: { Flags: { FLAG_START_WITHOUT_TIPS: 0x40000000 } } },
    '@kit.ArkUI': { promptAction: { ToastShowMode: { TOP_MOST: 1 } } }
  };
  const exports = {};
  new Function('require', 'exports', 'setTimeout', code)(name => kit[name], exports, options.wait ?? queueMicrotask);
  const context = { startAbility: async want => {
    assert.equal(want.bundleName, 'com.huawei.hmos.settings');
    if (want.abilityName) {
      assert.equal(want.abilityName, 'com.huawei.hmos.settings.MainAbility');
      assert.equal(want.uri, developer);
    } else {
      assert.equal(want.action, 'ohos.want.action.viewData');
      assert.equal(want.flags, 0x40000000);
    }
    const route = want.abilityName ? 'explicit' : want.uri;
    events.push(route);
    await options.start?.(route);
  } };
  const ui = { getHostContext: () => options.noContext ? undefined : context, getPromptAction: () => ({
    showDialog: async dialog => {
      assert.match(dialog.message, /软件版本.*7 次/);
      dialogs.push(dialog);
      events.push(dialog.title);
      if (options.dismiss) throw Object.assign(new Error('dismissed'), { code: 100001 });
      if (options.choose) {
        const label = await options.choose();
        return { index: dialog.buttons.findIndex(button => button.text === label) };
      }
      return { index: 0 };
    },
    openToast: async toast => { assert.match(toast.message, /系统.*开发者选项/); events.push('提示'); return 1; }
  }) };
  const action = new exports.DevToolsDeveloperSettings();
  return { events, dialogs, setMode: next => { value = next; },
    open: () => action.open(ui, () => events.push('手动路径')), cancel: () => action.cancel() };
}

test('明确关闭时只说明开启步骤，明确开启时直接启动', async () => {
  for (const value of ['false', '0', 'true', '1']) {
    const phone = device(value);
    await phone.open();
    assert.deepEqual(phone.events, value === 'false' || value === '0' ? ['请先开启开发者选项'] : [developer]);
  }
});

test('每次点击都重新读取开关，用户无需声明是否已开启', async () => {
  const phone = device('false');
  await phone.open();
  phone.setMode('true');
  await phone.open();
  phone.setMode('');
  await phone.open();
  assert.deepEqual(phone.events, ['请先开启开发者选项', developer, developer]);
  for (const dialog of phone.dialogs) {
    assert.deepEqual(dialog.buttons.map(button => button.text), ['知道了']);
  }
});

test('未注册 URI 的真机通过设置主 Ability 受理后不弹框', async () => {
  for (const value of ['true', undefined]) {
    const phone = device(value, { start: uri => { if (uri === developer) throw new Error('no match'); } });
    await phone.open();
    assert.deepEqual(phone.events, [developer, 'explicit']);
  }
});

test('子页启动失败时提示并打开系统，上一级也不可用时给出手动路径', async () => {
  for (const parentOpens of [true, false]) {
    const phone = device('true', { start: uri => {
      if (uri !== system || !parentOpens) throw new Error('unavailable');
    } });
    await phone.open();
    assert.deepEqual(phone.events, [developer, 'explicit', '提示', system, ...(parentOpens ? [] : ['手动路径'])]);
  }
  const emulator = device('true', { model: 'emulator', start: uri => {
    if (uri === developer) throw new Error('no match');
  } });
  await emulator.open();
  assert.deepEqual(emulator.events, [developer, '提示', system]);
});

test('读取失败、空值和未知值都先尝试直达，启动被受理就结束', async () => {
  for (const value of ['', undefined, 'invalid', new Error('unavailable')]) {
    const phone = device(value);
    await phone.open();
    assert.deepEqual(phone.events, [developer]);
    assert.equal(phone.dialogs.length, 0);
  }
});

test('状态未知且直达失败才提示，取消和系统返回均留在工具箱', async () => {
  for (const dismiss of [false, true]) {
    const phone = device('', { dismiss, start: () => { throw new Error('no match'); } });
    await phone.open();
    assert.deepEqual(phone.events, [developer, 'explicit', failed]);
    const dialog = phone.dialogs[0];
    assert.match(dialog.message, /设置 → 系统 → 开发者选项/);
    assert.match(dialog.message, /软件版本.*7 次/);
    assert.deepEqual(dialog.buttons.map(button => button.text), ['取消', parent, retry]);
  }
});

test('弹窗里可以重试直达，重试成功后不打开上级页面', async () => {
  let attempts = 0;
  const phone = device('', { choose: () => retry, start: () => {
    if (++attempts <= 2) throw new Error('first attempt failed');
  } });
  await phone.open();
  assert.deepEqual(phone.events, [developer, 'explicit', failed, developer]);
});

test('在弹窗中重试时若已能读到开关关闭，仅显示开启步骤', async () => {
  const phone = device('', { model: 'emulator', start: () => { throw new Error('no match'); }, choose: () => {
    phone.setMode('false');
    return retry;
  } });
  await phone.open();
  assert.deepEqual(phone.events, [developer, failed, '请先开启开发者选项']);
});

test('重试仍失败可以选择前往系统，系统也打不开时给出手动路径', async () => {
  for (const parentOpens of [true, false]) {
    const choices = [retry, parent];
    const phone = device(undefined, { model: 'emulator', choose: () => choices.shift(), start: uri => {
      if (uri !== system || !parentOpens) throw new Error('no match');
    } });
    await phone.open();
    assert.deepEqual(phone.events, [developer, failed, developer, failed, '提示', system,
      ...(parentOpens ? [] : ['手动路径'])]);
  }
});

test('缺少宿主上下文时显示查看步骤', async () => {
  const phone = device('true', { noContext: true });
  await phone.open();
  assert.deepEqual(phone.events, [unreadable]);
});

test('弹窗期间重复点击或离开工具箱，不会触发过期的按钮操作', async () => {
  for (const button of [parent, retry]) {
    let choose;
    const phone = device(undefined, { start: () => { throw new Error('no match'); },
      choose: () => new Promise(resolve => { choose = resolve; }) });
    const opened = phone.open();
    await new Promise(resolve => setImmediate(resolve));
    await phone.open();
    phone.cancel();
    choose(button);
    await opened;
    assert.deepEqual(phone.events, [developer, 'explicit', failed]);
  }
});

test('重复点击合并为一次，离开面板后不再因旧请求失败跳转', async () => {
  let reject;
  const phone = device('true', { start: () => new Promise((_resolve, fail) => { reject = fail; }) });
  const first = phone.open();
  await phone.open();
  phone.cancel();
  reject(new Error('late failure'));
  await first;
  assert.deepEqual(phone.events, [developer]);
});

test('系统页提示可见期间返回，不再启动设置', async () => {
  let finishHint;
  const phone = device('true', { model: 'emulator', start: () => { throw new Error('no match'); },
    wait: callback => { finishHint = callback; } });
  const opened = phone.open();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(phone.events, [developer, '提示']);
  phone.cancel();
  finishHint();
  await opened;
  assert.deepEqual(phone.events, [developer, '提示']);
});
