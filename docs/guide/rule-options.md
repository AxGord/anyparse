# Rule options

The keys a rule reads from its `rules` entry of an `apq.json` ([configuration](lint-config.md)), besides `enabled`,
`severity`, `excludePaths` and `excludeTypes`, which every rule takes. A rule not listed reads no option. A key outside
this list is said as a config note naming the rule and the keys it accepts.

The table is generated from the rule registry by `node bin/dev.js docs-gen`; a suite test fails when it is stale, so
regenerate it instead of editing it.

<!-- docs-gen:begin rule-options -->
| rule | category | options |
|---|---|---|
| `hoist-common-import` | `imports` | `minModules` `threshold` `sinkThreshold` `usingAllowList` |
| `import-order` | `imports` | `order` `usingAfterImports` |
| `shorten-type-ref` | `imports` | `importMinUses` `valuePositions` |
| `doc-coverage` | `docs` | `requireTypeDoc` `requireMemberDoc` `includeConstructor` |
| `doc-length` | `docs` | `max` |
| `naming` | `naming` | `handlerSuffix` `catchVarName` |
| `no-underscore-prefix` | `naming` | `allowInheritedShadow` `params` `locals` |
| `avoid-any` | `types` | `excludeMeta` |
| `avoid-dynamic` | `types` | `excludeMeta` `boundaryCalls` |
| `catch-dynamic` | `types` | `fixLoggingUses` |
| `explicit-local-type` | `types` | `maxInferredTypeLength` |
| `map-as-set` | `types` | `set` `bits` |
| `member-order` | `members` | `maxRelocatedLines` `movableArglessNew` `separateInlineSubgroup` `separateDocumentedSubgroup` |
| `module-type-order` | `members` | `mainType` `kindOrder` `afterMainKinds` |
| `prefer-final-class` | `members` | `closedWorld` |
| `trivial-getter` | `members` | `maxBypassWrites` |
| `unused-enum-abstract-value` | `members` | `fix` |
| `unused-parameter` | `unused` | `renameSilence` |
| `unused-return-value` | `unused` | `allow` |
| `case-pattern-separator` | `control` | `style` |
| `invert-negated-if-else` | `control` | `defaultLast` `keepDefaultElse` |
| `fold-adjacent-string-literals` | `literals` | `concatFoldingMacros` |
| `magic-number` | `literals` | `literalTables` `ignoreCallArguments` `ignore` |
| `string-literal-dup` | `literals` | `minOccurrences` `minLength` `literalMacros` |
| `duplicate-comparator` | `expressions` | `compare` `keyed` |
| `prefer-compare-function` | `expressions` | `compare` |
| `prefer-copy-method` | `expressions` | `types` |
| `prefer-split-part` | `expressions` | `textTools` |
| `prefer-static-extension` | `expressions` | `types` `addUsing` |
| `redundant-parens` | `expressions` | `atoms` `sameOperatorLeft` `comparisonOperands` `additiveOperands` |
| `anon-type-dup` | `design` | `minOccurrences` `minFields` `named` |
| `complexity` | `design` | `max` |
| `fix-text-syntax` | `design` | `roots` `sinks` `spanField` `textField` `baseline` |
| `guard-pin-arm-reach` | `design` | `pinMeta` `guardArgument` `killerMeta` `armRegistry` |
| `hand-source-scanner` | `design` | `allow` `nameSearchAllow` |
| `helper-copy` | `design` | `homes` |
| `oversized-type` | `design` | `maxMembers` `maxLines` `grants` |
| `prefer-api-idiom` | `design` | `idioms` |
| `prefer-existing-typedef` | `design` | `acrossModules` |
| `prefer-final-typedef-fields` | `design` | `mode` |
| `prefer-helper` | `design` | `marker` |
| `prefer-read-only-array` | `design` | `closedWorld` |
| `refusal-assert-ignores-message` | `design` | `refusalConstructors` `passCalls` |
| `repeated-cast` | `design` | `minChecked` `minUnchecked` |
| `thread-safety` | `design` | `sinks` `spawns` `marshals` `lockPairs` `quietRoots` `reentrantLocks` `throwers` `neverInvokes` `mainThreadChecks` `exclude` `shortSinks` `iterates` `registers` `sharedLocks` `nonThrowing` `runsOnce` `nonBlocking` `libraryBodies` `closedWorld` `compilerFacts` `repeatBudgetMs` `boundedRepeats` |
| `typed-event-constant` | `design` | `eventBase` `typeAbstract` `listenerMethods` |
| `zero-count-unparsed-fixture` | `design` | `zeroAsserts` `countFields` `sourceFields` `skipParseTests` |
<!-- docs-gen:end rule-options -->
