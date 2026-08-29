bool shouldIgnore(String name) {
  const ignoredNames = [
    'node_modules',
    '.git',
    '.dart_tool',
    'build',
    '.idea',
    '.vscode',
  ];

  if (name.startsWith('.') && name != '.syncodeignore') {
    return true;
  }

  return ignoredNames.contains(name);
}
