// Run the library's platform-independent ArkTS tests with the compiler bundled in DevEco Studio.
const fs = require('node:fs');
const path = require('node:path');
const ts = require(path.join(process.env.DEVECO_HOME || 'C:/Program Files/Huawei/DevEco Studio',
  'tools/hvigor/hvigor/node_modules/typescript'));

require.extensions['.ets'] = (module, filename) => {
  const { outputText } = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    fileName: filename.replace(/\.ets$/, '.ts')
  });
  module._compile(outputText, filename);
};
