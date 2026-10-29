package anyparse.grammar.haxe;

import anyparse.query.GrammarPlugin.RefShape;

/**
 * The Haxe grammar's `RefShape`: every node kind the grammar-agnostic reference, scope, write and
 * layout walkers have to be told about, with the reason each kind is in the list it is in.
 *
 * Its own module rather than the body of `HaxeQueryPlugin.refShape` because it is a TABLE, not
 * plugin behaviour — the one place a ctor added to the grammar has to be classified — and it
 * outgrew the plugin it was declared in. The plugin answers `GrammarPlugin.refShape` from here, the
 * way it answers `namingSupport` from `HaxeNamingSupport`; `DECL_HOST_KINDS` stays shared with the
 * plugin's `metaShape` so the two contracts cannot drift.
 */
@:nullSafety(Strict)
final class HaxeRefShape {

	/**
	 * Binding-declaration kinds shared by `shape` and `HaxeQueryPlugin.metaShape` so the two contracts cannot
	 * drift: top-level type decls, statement-level var bindings (plus their expression-position
	 * `VarExpr` / `FinalExpr` twins wrapping the same `HxVarDecl`), class-member bindings,
	 * function parameters (`HxParam`'s three Alt branches, reused verbatim by `HxLambdaParam`),
	 * enum constructors (`SimpleCtor` / `ParamCtor`, so an annotation on a ctor attributes to it
	 * — the `MetaCall` and ctor nodes flatten as spanned siblings, and `Meta.followingDeclHost`
	 * resolves once the kind is a host), and anon-struct fields (`VarField` / `FinalField` /
	 * `FnField`, reached once `appendNodes` descends the anon `type`; the bare `name:Type` forms
	 * reuse `Required` / `Optional`).
	 *
	 * `VarMore` is the `@:spanned('VarMore')` struct carrying every binding AFTER the first in
	 * `var a = 1, b = 2;` — without it those bindings had no declaration node and `Refs` could
	 * not resolve their uses. `KeyValueBinder` is the same lift for the VALUE binder of `for (k
	 * => v in m)`: the loop node's own name is the KEY. It is a decl host rather than a
	 * `selfScopeDeclKinds` entry because it opens no scope of its own — it binds into the frame
	 * the LOOP opens, which is what `Refs.collectIntoMulti` does with a decl-host child.
	 *
	 * `LocalFnStmt` and `LocalInlineFnStmt` are the two projections of a local `function`
	 * statement (the grammar folds the `inline` keyword into its own ctor), and both bind their
	 * name into the ENCLOSING body while opening a scope of their own for their parameters (see
	 * `scopeKinds`); decl hosts, not `selfScopeDeclKinds`, because the scope they open is not the
	 * one their own name lives in. `NamedFnExpr` — the same keyword in VALUE position, `final f =
	 * function nn(a) { … }` — binds its name the same way: the compiler makes it readable AFTER
	 * the literal in the enclosing block and nowhere else, and self-recursion needs no extra
	 * entry because the binding is position-scoped at the literal's own start. Without this
	 * entry a self-recursive call bound to whatever ELSE in scope carried the name.
	 *
	 * The three `final` / `abstract` type-declaration forms name themselves through their own
	 * ctors, so each needs its own entry. `ClassForm` is the inner form of a `final class`, which
	 * projects as `FinalDecl(ClassForm …)`: the NAME sits on the inner node and `FinalDecl`
	 * carries none, so the wrapper is deliberately absent — the normalisation
	 * `SELECT_KIND_EQUIVALENCE` and `RefactorSupport.typeDeclOf` already apply.
	 * `AbstractClassDecl` and `EnumAbstractDecl` are ctors of their own and name themselves.
	 * They join `HOISTING_SCOPE_KINDS`, which names all three for the mirror reason.
	 */
	public static final DECL_HOST_KINDS: Array<String> = [
		'VarDecl',
		'FnDecl',
		'LocalFnStmt',
		'LocalInlineFnStmt',
		'NamedFnExpr',
		'ClassDecl',
		'ClassForm',
		'AbstractClassDecl',
		'InterfaceDecl',
		'EnumDecl',
		'AbstractDecl',
		'EnumAbstractDecl',
		'TypedefDecl',
		'VarMember',
		'FinalMember',
		'FnMember',
		'FinalModifiedMember',
		'VarStmt',
		'FinalStmt',
		'StaticVarStmt',
		'StaticFinalStmt',
		'VarMore',
		'VarExpr',
		'FinalExpr',
		'Required',
		'Optional',
		'Rest',
		'SimpleCtor',
		'ParamCtor',
		'VarField',
		'FinalField',
		'FnField',
		'KeyValueBinder'
	];

	/** The annotation that keeps a static out of `using`: calling it as an extension does not compile. */
	private static inline final NO_USING_META: String = '@:noUsing';

	/**
	 * The assignment-operator kinds — plain `=` plus every compound form, in
	 * declaration order. Shared so `refShape`'s `writeParentKinds` (which adds the
	 * increment / decrement mutators) and its `delimitedTailChildKinds` (which adds
	 * `Call`) cannot drift: a new assignment operator is added here once and both
	 * lists follow.
	 */
	private static final ASSIGN_KINDS: Array<String> = [
		'Assign',
		'AddAssign',
		'SubAssign',
		'MulAssign',
		'DivAssign',
		'ModAssign',
		'ShlAssign',
		'ShrAssign',
		'UShrAssign',
		'BitOrAssign',
		'BitAndAssign',
		'BitXorAssign',
		'NullCoalAssign',
		'BoolAndAssign',
		'BoolOrAssign'
	];

	/**
	 * Scope kinds whose declarations ARE forward-visible - the type bodies. A method may read a
	 * field declared below it and the compiler binds it, so these frames hoist.
	 *
	 * `final class` projects as `FinalDecl(ClassForm …)` and `abstract class` as
	 * `AbstractClassDecl`; both hold instance fields whose bare (non-`this`) references resolve
	 * only if the class body opens a scope frame.
	 *
	 * `enum abstract` gets its own ctor rather than reusing `AbstractDecl`, so it needs its own
	 * entry. Its members hoist like any other type body's: `final A = B + 1; final B = 1;`
	 * compiles and evaluates `A` to 2.
	 */
	private static final HOISTING_SCOPE_KINDS: Array<String> = [
		'ClassDecl',
		'ClassForm',
		'AbstractClassDecl',
		'InterfaceDecl',
		'AbstractDecl',
		'EnumAbstractDecl',
		'EnumDecl',
		'TypedefDecl'
	];

	/**
	 * Scope kinds whose declarations take effect only from their own position onward — every
	 * construct above whose body is a statement list or a parameter list. Haxe hoists neither a
	 * local `var` nor a local `function` (a call before its declaration is `Unknown
	 * identifier`), so a reference that precedes one binds to whatever encloses it: the member
	 * of the same name, most often.
	 *
	 * `CatchClause` is surfaced by `appendNodes` from the `@:spanned('CatchClause')` paired
	 * struct; it opens a scope (the clause body) and self-binds the exception name into that
	 * frame (see `selfScopeDeclKinds`). A parameter needs no entry of its own: a function frame
	 * pre-collects only its own params (the walk stops at the body's `BlockBody`), so they stay
	 * visible to the whole body while the body's own declarations become position-scoped.
	 *
	 * A local `function f(...) {...}` statement opens its own frame — without it sibling local
	 * fns' same-named params collect into the ENCLOSING function's frame and reads mis-bind
	 * across siblings. `inline function` is the same construct with the keyword folded into its
	 * own ctor, and it is the form this project's Haxe style prescribes for a local helper — the
	 * two must never diverge HERE. They deliberately do diverge in `functionKinds` /
	 * `localFunctionKinds` below, which measure complexity units rather than scopes; a consumer
	 * that wants the scope reading unions `inlineFunctionKinds` back in (enumerate them with
	 * `hxq mentions inlineFunctionKinds src/` rather than trusting a list here).
	 *
	 * `ThinArrow` is the bare `arg -> body` lambda, and it belongs here for the same reason the
	 * two parenthesised forms and `FnExpr` do: it binds a parameter that dies at the body's end.
	 * The grammar spells it as a Pratt infix ctor, so its parameter reaches the tree as an
	 * `IdentExpr` — `HxArrowParamProjection` re-labels it `Required` before any consumer sees
	 * it. Without BOTH halves the parameter was a read of whatever enclosed the lambda.
	 * `NamedFnExpr` is `function nn(a) { … }` in VALUE position and belongs here for exactly the
	 * reason the anonymous `FnExpr` does; without it the parameter collected into the ENCLOSING
	 * function's frame and an outer read of the same name resolved to it (the anonymous spelling
	 * one line above was correct throughout, which kept it hidden). The name `nn` itself does
	 * NOT live in this frame — it binds into the enclosing body, so it is a `DECL_HOST_KINDS`
	 * entry too.
	 */
	private static final POSITION_SCOPED_SCOPE_KINDS: Array<String> = [
		'FnDecl',
		'FnExpr',
		'FnMember',
		'FinalModifiedMember',
		'LocalFnStmt',
		'LocalInlineFnStmt',
		'ThinParenLambdaExpr',
		'ParenLambdaExpr',
		'ThinArrow',
		'NamedFnExpr',
		'BlockBody',
		'BlockExpr',
		'BlockStmt',
		'ForStmt',
		'ForExpr',
		'CatchClause'
	];

	/**
	 * The `switch` arms - see `RefShape.branchScopeKinds`. Position-scoped like any other
	 * statement list, so they join `positionScopedKinds` too; kept apart from
	 * `POSITION_SCOPED_SCOPE_KINDS` because an arm is NOT a `scopeKinds` entry (a dozen checks
	 * read that vocabulary as "lexical container of a declaration", which an arm is not).
	 */
	private static final BRANCH_SCOPE_KINDS: Array<String> = ['CaseBranch', 'DefaultBranch'];

	/**
	 * The value-position hosts a conditional chain may be rewritten inside. Shared so
	 * `switchExpressionHostKinds` and `ifExpressionChainHostKinds` (which adds the
	 * arrow-lambda bodies and the two switch-ARM kinds) cannot drift: a new value host is
	 * added here once and both follow. A `case` arm is deliberately absent from THIS
	 * constant — a `switch` spliced into a `switch` arm reads worse than the chain it
	 * replaced, while an if-chain there is the ladder the formatter already renders, so
	 * only the if-chain seam adds it. A bare expression STATEMENT is absent from both: a
	 * chain there yields no value anyone reads, and rewriting it would hand the site to
	 * the statement-side rule family instead.
	 */
	private static final SWITCH_EXPRESSION_HOST_KINDS: Array<String> = [
		'ReturnStmt',
		'ReturnExpr',
		'VarStmt',
		'FinalStmt',
		'VarMember',
		'FinalMember',
		'Assign'
	];

	/** The table itself — see the type doc; every list carries the reason for its members beside it. */
	public static function shape(): RefShape {
		// Identifier references come exclusively through `HxExpr.IdentExpr(v)`
		// — the bare-identifier branch of the expression enum. Field-access
		// (`obj.foo`), method names, type references, and string-literal
		// fragments live under different ctors and never match.
		//
		// Decl-host kinds: any enum-ctor whose `extractName` walk resolves
		// to a binding declaration. Top-level type decls (`ClassDecl`, …),
		// statement-level var bindings (`VarStmt`, `FinalStmt`, plus the
		// expression-position `VarExpr`/`FinalExpr` twins, top-level
		// `VarDecl`/`FnDecl`), class-member bindings (`VarMember`,
		// `FinalMember`, `FnMember`, plus `FinalModifiedMember` — the `final`
		// METHOD form, whose name `extractName` lifts off the inner
		// `HxFinalModifierMember.fn`), and function-parameter bindings via
		// `HxParam`'s three Alt branches (`Required`/`Optional`/`Rest`).
		//
		// Scope kinds: every node that opens a fresh lexical scope. The
		// walker pushes a frame on enter and pops on exit; decl-hosts
		// found in that scope's subtree (until the next inner scope
		// boundary) become the frame's bindings, shadowing same-named
		// outer bindings for any Read encountered inside.
		//
		// For-loop iterator variables (`HxForStmt.varName` /
		// `HxForExpr.varName`) are resolved (Phase 3.2b-alpha): the
		// `varName` alias in `extractName` surfaces the iterator on the
		// `ForStmt` / `ForExpr` ctor's `name` slot, and both kinds are
		// listed in `selfScopeDeclKinds` so the iterator self-binds into
		// the loop's own scope frame, visible to reads inside the body,
		// not after the loop.
		//
		// Catch-clause exception names are resolved (Phase 3.2b-beta):
		// the three catch-clause typedefs are tagged
		// `@:spanned('CatchClause')`, so the paired struct carries a
		// per-instance `_span` + `_kind` and `appendNodes` surfaces it as
		// an addressable node. `CatchClause` is a self-scoped decl (the
		// exception var is visible only inside the clause body, like a
		// for-loop iterator).
		//
		// A lambda parameter reached the same list through a
		// `@:spanned('LambdaParam')` typedef until `HxLambdaParam` became
		// an `Optional` / `Required` Alt enum; the retired `LambdaParam`
		// kind then sat in this list, in `HaxeNamingSupport.categoryOf` and
		// in `FieldRefScan.bindsNameHere`, matching nothing and reported by
		// nothing. `RefShapeKindProjectionTest` is what keeps the next
		// retired kind from lasting.
		//
		// Write-parent kinds: ctors on `HxExpr` whose first positional
		// child carries the binding being modified. `Assign(left, right)`
		// plus every compound `*Assign(left, right)` variant, and the
		// four increment/decrement ctors `PreIncr` / `PreDecr` /
		// `PostIncr` / `PostDecr` (`HxExpr`, P5 Slice H — their single
		// operand at child-0 is the mutated binding). `x++` / `++x` both
		// read and write `x`; mirroring the compound-assign convention
		// they classify as a single Write. Per the `RefShape` docstring,
		// only the direct child-0 IdentExpr is reclassified Write;
		// `obj.x = …` and `arr[i] = …` keep `obj` / `arr` / `i` as Reads.
		// Every module-level VALUE binding this grammar can spell, and nothing else: a top-level
		// `var` / `function` (Haxe 4.2+) plus `VarForm`, the inner node of the `final` spelling,
		// which projects as `FinalDecl(VarForm name …)` with the name one level down and is
		// absent from `DECL_HOST_KINDS`. Every type-declaration kind is deliberately OUT — a
		// module-level type named after a value shadows nothing, and a `final class` reaches the
		// same wrapper as `FinalDecl(ClassForm …)`. Enumerated against `HxDecl`'s ctors, where
		// these three are the only value binders. See `RefShape.moduleValueDeclKinds`.
		final moduleValueDeclKinds: Array<String> = ['VarDecl', 'FnDecl', 'VarForm'];
		// Every lexical scope, hoisting ones first. The two halves are named separately so
		// `positionScopedKinds` below is their difference by construction rather than by hand:
		// a kind added to one list can no longer go missing from the other.
		final scopeKinds: Array<String> = HOISTING_SCOPE_KINDS.concat(POSITION_SCOPED_SCOPE_KINDS);
		// `CondSemiAssignStmt` assigns its child 0 like `Assign`, its value a `#if` region of statements
		final writeParentKinds: Array<String> = ASSIGN_KINDS.concat(['PreIncr', 'PreDecr', 'PostIncr', 'PostDecr', 'CondSemiAssignStmt']);
		// Self-scoped decl kinds: scope-introducers whose own name binds
		// into the frame they open (the for-loop iterator pattern). Listed
		// in scopeKinds, absent from declHostKinds — the binding is visible
		// only inside the loop, not to enclosing-scope siblings.
		final selfScopeDeclKinds: Array<String> = ['ForStmt', 'ForExpr', 'CatchClause'];
		final table: RefShape = new RefShape(
			'IdentExpr', DECL_HOST_KINDS, moduleValueDeclKinds, scopeKinds, writeParentKinds, selfScopeDeclKinds
		);
		table.selfReferenceText = 'this';
		table.superReferenceText = 'super';
		table.underlyingThisTypeKinds = ['AbstractDecl', 'EnumAbstractDecl'];
		// A `switch` arm confines the locals declared in it — see `RefShape.branchScopeKinds`.
		table.branchScopeKinds = BRANCH_SCOPE_KINDS;

		// `package a.b;` / `import c.d.E;` are dotted module paths, not references.
		table.modulePathKinds = ['PackageDecl', 'ImportDecl'];
		// The non-hoisting half of `scopeKinds`, plus the `switch` arms — which are
		// position-scoped statement lists too, but live in `branchScopeKinds` rather than
		// `scopeKinds`. `RefShape.positionScopedKinds` is keyed by kind, not by vocabulary.
		table.positionScopedKinds = POSITION_SCOPED_SCOPE_KINDS.concat(BRANCH_SCOPE_KINDS);
		// A data member of an abstract is static whether or not it says so: Haxe refuses
		// `Cannot declare member variable in abstract`, which is what makes every value of
		// an `enum abstract` a static field with no modifier to read.
		table.implicitStaticFieldHostKinds = ['AbstractDecl', 'EnumAbstractDecl'];
		table.upperInitialNeverCaptures = true;
		// All THREE `macro` quotation spellings, not just the expression one: `macro : T`
		// (`MacroTypeExpr`) and `macro class { … }` (`MacroClassExpr`) reify a type and a type
		// declaration exactly as `macro { … }` reifies an expression. Leaving the two out made every
		// central reification gate — `ReificationScan.withoutQuoted` and each check's own descent stop
		// — blind to them, and `shorten-type-ref` then rewrote `macro :pony.events.Signal2<…>` to a
		// short name whose import it added to THIS file, while the reified type is spliced into
		// another module where that import does not apply.
		table.opaqueKinds = ['MacroExpr', 'MacroTypeExpr', 'MacroClassExpr'];
		table.quotationTypes = [
			'MacroExpr' => 'haxe.macro.Expr',
			'MacroTypeExpr' => 'haxe.macro.Expr.ComplexType',
			'MacroClassExpr' => 'haxe.macro.Expr.TypeDefinition'
		];
		table.interpolationKinds = ['DollarBlockExpr', 'DollarReifExpr'];
		table.branchKinds = [
			'IfStmt',
			'IfExpr',
			'WhileStmt',
			'WhileExpr',
			'DoWhileStmt',
			'DoWhileExpr',
			'ForStmt',
			'ForExpr',
			'CaseBranch',
			'CatchClause',
			'And',
			'Or',
			'Ternary',
			'NullCoal'
		];
		table.functionKinds = ['FnMember', 'FinalModifiedMember', 'FnDecl', 'LocalFnStmt'];
		table.localFunctionKinds = ['LocalFnStmt'];
		table.inlineFunctionKinds = ['LocalInlineFnStmt'];
		table.lambdaKinds = ['ThinArrow', 'ThinParenLambdaExpr', 'ParenLambdaExpr', 'FnExpr'];
		table.comparisonKinds = ['Eq', 'NotEq', 'Lt', 'LtEq', 'Gt', 'GtEq', 'And', 'Or'];
		table.assignKind = 'Assign';
		table.addAssignKind = 'AddAssign';
		table.callKind = 'Call';
		table.caseBranchKind = 'CaseBranch';
		table.orPatternKind = 'BitOr';
		table.switchKinds = ['SwitchStmt', 'SwitchStmtBare', 'SwitchExpr', 'SwitchExprBare'];
		// The two statement-position forms of the four above: a bare subject and a parenthesised one. Their
		// arms need not be exhaustive, which is what a case guard's fall-through to the next pattern requires.
		table.switchStatementKinds = ['SwitchStmt', 'SwitchStmtBare'];
		// The subject types Haxe never exhaustiveness-checks a statement switch over, so
		// an arm may be deleted without the compiler noticing the arm list shrank. Every
		// enum / enum abstract / Bool is deliberately absent: those ARE checked.
		table.openSwitchSubjectTypes = ['Int', 'UInt', 'Float', 'Single', 'String'];
		table.parenKind = 'ParenExpr';
		table.parenDelimiters = { open: '(', close: ')' };
		table.exprEndingCloser = '}';
		table.macroModifierKind = 'Macro';
		table.boolLitKind = 'BoolLit';
		table.nonNullBoolTypeName = 'Bool';
		table.branchConditionKinds = ['IfStmt', 'IfExpr'];
		table.emptyStmtKind = 'EmptyStmt';
		table.statementTerminator = ';';
		table.emptyMemberKind = 'EmptySemiMember';
		// `VarMore` IS a local declaration — the binding after the comma in
		// `var a = 1, b = 2;`. Listed here so every declaration-walking check reaches it
		// with its existing logic. NOT in `mutableLocalDeclKinds`: the kind alone cannot
		// say whether the list it continues is `var` or `final`, and Haxe has no way to
		// mark ONE binding of a multi-var `final` anyway.
		table.localDeclKinds = ['VarStmt', 'FinalStmt', 'VarMore'];
		table.localDeclContinuationKinds = ['VarMore'];
		table.localDeclExprKinds = ['VarExpr', 'FinalExpr'];
		table.staticLocalDeclKinds = ['StaticVarStmt', 'StaticFinalStmt'];
		table.mutableLocalDeclKinds = ['VarStmt'];
		table.ifStatementKinds = ['IfStmt'];
		table.ifExpressionKinds = ['IfExpr'];
		table.tryStatementKinds = ['TryCatchStmt', 'TryCatchStmtBare'];
		table.tryExpressionKinds = ['TryExpr'];
		table.equalityKinds = ['Eq', 'NotEq'];
		table.optionalParamKind = 'Optional';
		table.restParamKind = 'Rest';
		table.optionalValueTypeName = 'Null';
		table.optionalFieldMetaName = '@:optional';
		table.execution = {
			implicitConversionMetaName: '@:from',
			implicitOutwardConversionMetaName: '@:to',
			// what `thread-safety` counts as blocking with no configuration: each one waits on a file, a process, a socket, a
			// database, a timer or another thread (verified against the std of Haxe 4.3.7); `FileSystem.absolutePath` is no
			// entry, its cpp body reads `Sys.getCwd` and joins strings
			blockingLibraryCalls: [
				'sys.io.File.getContent',
				'sys.io.File.saveContent',
				'sys.io.File.getBytes',
				'sys.io.File.saveBytes',
				'sys.io.File.read',
				'sys.io.File.write',
				'sys.io.File.append',
				'sys.io.File.update',
				'sys.io.File.copy',
				'sys.FileSystem.exists',
				'sys.FileSystem.rename',
				'sys.FileSystem.stat',
				'sys.FileSystem.fullPath',
				'sys.FileSystem.isDirectory',
				'sys.FileSystem.createDirectory',
				'sys.FileSystem.deleteFile',
				'sys.FileSystem.deleteDirectory',
				'sys.FileSystem.readDirectory',
				'Sys.sleep',
				'Sys.command',
				'Sys.getChar',
				'sys.io.Process.new',
				'sys.io.Process.exitCode',
				'sys.io.Process.close',
				'sys.net.Socket.connect',
				'sys.net.Socket.accept',
				'sys.net.Socket.read',
				'sys.net.Socket.write',
				'sys.net.Socket.waitForRead',
				'sys.net.Socket.select',
				'sys.net.UdpSocket.readFrom',
				'sys.net.UdpSocket.sendTo',
				'sys.ssl.Socket.handshake',
				'sys.net.Host.new',
				'sys.net.Host.reverse',
				'sys.db.Sqlite.open',
				'sys.db.Mysql.connect',
				'sys.db.Connection.request',
				'sys.db.Connection.startTransaction',
				'sys.db.Connection.commit',
				'sys.db.Connection.rollback',
				'sys.db.Connection.close',
				// a result set steps its statement as it is read (cpp `result_next`)
				'sys.db.ResultSet.hasNext',
				'sys.db.ResultSet.next',
				'sys.db.ResultSet.results',
				// reading `length` runs its getter, which on cpp steps every row into a cache (`result_next`)
				'sys.db.ResultSet.get_length',
				'sys.Http.request',
				'sys.Http.customRequest',
				'sys.Http.requestUrl',
				'sys.thread.Lock.wait',
				'sys.thread.Mutex.acquire',
				'sys.thread.Deque.pop',
				'sys.thread.Condition.wait',
				'sys.thread.Semaphore.acquire',
				'sys.thread.Semaphore.tryAcquire',
				'sys.thread.Thread.readMessage',
				// a loop runs the thread's events until none is left; `wait` sleeps until one is due
				'sys.thread.EventLoop.loop',
				'sys.thread.EventLoop.wait',
				'sys.thread.Thread.runWithEventLoop'
			],
			// a stream of unknown kind — a process's, a socket's, a file's — is read and written as one that blocks
			blockingLibraryTypes: ['sys.io.FileInput', 'sys.io.FileOutput', 'haxe.io.Input', 'haxe.io.Output'],
			nativeCodeMetaNames: ['@:native', '@:hlNative', '@:functionCode'],
			nativeLoaderCalls: [
				'cpp.Lib.load',
				'cpp.Lib.loadLazy',
				'cpp.Prime.load',
				'cpp.Prime._loadPrime',
				'cpp.Prime.nekoLoad',
				'lime.system.CFFI.load'
			],
			nativeCodeCalls: ['cpp.Syntax.code', 'cpp.Syntax.plainCode'],
			targetCodeNameAffix: '__',
			literalAbstractTypes: ['Rest' => 'Rest', 'Arrow' => 'Map'],
			literalConstructions: ['RegexLit' => 'EReg', 'ArrayExpr' => 'Map'],
			comprehensionCalls: ['ArrayExpr' => 'Array.push'],
			classValueTypeName: 'Class',
			concatenationKinds: ['Add', 'AddAssign'],
			stringConversionMethodNames: ['toString'],
			stringConversionCalls: ['Std.string'],
			indexAccessMetaName: '@:arrayAccess',
			indexOperatorOverloadKind: 'ArrayExpr',
			compoundAssignOperators: [
				'AddAssign' => 'Add',
				'SubAssign' => 'Sub',
				'MulAssign' => 'Mul',
				'DivAssign' => 'Div',
				'ModAssign' => 'Mod',
				'ShlAssign' => 'Shl',
				'ShrAssign' => 'Shr',
				'UShrAssign' => 'UShr',
				'BitOrAssign' => 'BitOr',
				'BitAndAssign' => 'BitAnd',
				'BitXorAssign' => 'BitXor',
				'NullCoalAssign' => 'NullCoal',
				'BoolAndAssign' => 'And',
				'BoolOrAssign' => 'Or'
			],
			reflectiveNameCalls: [
				'Reflect.field' => 1,
				'Reflect.setField' => 1,
				'Reflect.getProperty' => 1,
				'Reflect.setProperty' => 1,
				'Reflect.hasField' => 1,
				'Reflect.deleteField' => 1
			],
			reflectiveInstantiationCalls: ['Type.createInstance'],
			nonMutatingArrayMethods: [
				'concat',
				'contains',
				'copy',
				'filter',
				'indexOf',
				'iterator',
				'join',
				'keyValueIterator',
				'lastIndexOf',
				'map',
				'slice',
				'toString'
			],
			mutatingArrayMethods: [
				'insert',
				'pop',
				'push',
				'remove',
				'resize',
				'reverse',
				'shift',
				'sort',
				'splice',
				'unshift'
			],
			fixedLengthArrayTypes: ['haxe.ds.Vector'],
			integerFoldOperators: ['Add' => 'add', 'Sub' => 'subtract', 'Mul' => 'multiply'],
			mapTypeNames: ['Map', 'IntMap', 'StringMap', 'ObjectMap', 'EnumValueMap', 'BalancedTree'],
			nonMutatingMapMethods: ['copy', 'exists', 'get', 'iterator', 'keyValueIterator', 'keys', 'toString'],
			mutatingMapMethods: ['arrayWrite', 'clear', 'remove', 'set'],
			implicitCallMetaNames: ['@:op', '@:arrayAccess', '@:from', '@:to', '@:resolve'],
			implicitCallNames: ['toString', 'iterator', 'hasNext', 'next', 'keyValueIterator'],
			// `haxe.Serializer` / `Unserializer` call these through `Reflect`, a class implementing `Dynamic` falls back to `resolve`
			reflectivelyCalledNames: ['hxSerialize', 'hxUnserialize', 'resolve'],
			iterableMethodNames: ['iterator', 'keyValueIterator'],
			implicitConstructionTypeMetaNames: ['@:structInit'],
			extensionTypeMetaNames: ['@:using'],
			extensionExcludingMetaNames: [NO_USING_META],
			enumConstructorKinds: ['SimpleCtor', 'ParamCtor'],
			pureLibraryTypes: ['Math', 'String', 'StringTools'],
			pureLibraryCalls: [
				'Std.int',
				'Std.parseInt',
				'Std.parseFloat',
				'Std.random',
				'Std.isOfType',
				'StringBuf.add',
				'StringBuf.addChar',
				'StringBuf.addSub',
				'StringBuf.toString',
				// reads the process environment: no callback, on every target
				'Sys.getEnv'
			],
			statefulLibraryCalls: [
				'Std.random',
				'Math.random',
				// what it reads, `Sys.putEnv` writes
				'Sys.getEnv',
				'StringBuf.add',
				'StringBuf.addChar',
				'StringBuf.addSub'
			],
			freshReturningMethods: ['Array' => ['copy', 'concat', 'map', 'filter', 'slice'], 'String' => ['split']],
			modelledKinds: [
				'Abstract',
				'AbstractClassDecl',
				'AbstractDecl',
				'AbstractHead',
				'AbstractKw',
				'Add',
				'AddAssign',
				'And',
				'Anon',
				'AnonHead',
				'ArrayExpr',
				'Arrow',
				'ArrowFn',
				'Assign',
				'BitAnd',
				'BitAndAssign',
				'BitNot',
				'BitOr',
				'BitOrAssign',
				'BitXor',
				'BitXorAssign',
				'Block',
				'BlockBody',
				'BlockExpr',
				'BlockStmt',
				'BoolAndAssign',
				'BoolLit',
				'BoolOrAssign',
				'BracketExprListType',
				'BreakExpr',
				'BreakStmt',
				'Call',
				'Capture',
				'CaseBranch',
				'CastExpr',
				'CatchClause',
				'ClassDecl',
				'ClassForm',
				'ClassHead',
				'CondBody',
				'CondNameFnMember',
				'CondSpliceTail',
				'Conditional',
				'ConditionalArgs',
				'ConditionalExpr',
				'ConditionalType',
				'ConstStringType',
				'ContinueExpr',
				'ContinueStmt',
				'DefaultBranch',
				'Div',
				'DivAssign',
				'DoWhileExpr',
				'DoWhileStmt',
				'Dollar',
				'DoubleStringExpr',
				'Dynamic',
				'ECheckTypeExpr',
				'EmptySemiMember',
				'EmptyStmt',
				'EnumAbstractDecl',
				'EnumDecl',
				'EnumKw',
				'Eq',
				'ExprBody',
				'ExprStmt',
				'ExtendsClause',
				'ExtendsField',
				'Extern',
				'Field',
				'FieldAccess',
				'FinalDecl',
				'FinalExpr',
				'FinalField',
				'FinalKw',
				'FinalMember',
				'FinalModifiedMember',
				'FinalStmt',
				'FloatLit',
				'FnDecl',
				'FnExpr',
				'FnField',
				'FnMember',
				'ForExpr',
				'ForStmt',
				'ForceFieldAccess',
				'FromClause',
				'Gt',
				'GtEq',
				'HexLit',
				'Ident',
				'IdentExpr',
				'IfExpr',
				'IfStmt',
				'ImplementsClause',
				'ImportAliasDecl',
				'ImportAliasInDecl',
				'ImportDecl',
				'ImportWildDecl',
				'In',
				'IndexAccess',
				'Inline',
				'InlineExpr',
				'InnerDoWhile',
				'IntLit',
				'InterfaceDecl',
				'Interval',
				'Is',
				'KeyValueBinder',
				'Literal',
				'LoneDollar',
				'LocalFnStmt',
				'LocalInlineFnStmt',
				'Lt',
				'LtEq',
				'Meta',
				'MetaCall',
				'MetaExpr',
				'MetaStmt',
				'Mod',
				'ModAssign',
				'Mul',
				'MulAssign',
				'Named',
				'NamedFnExpr',
				'NamedHead',
				'NamedParam',
				'Neg',
				'NewExpr',
				'NoBody',
				'Not',
				'NotEq',
				'NullCoal',
				'NullCoalAssign',
				'NullLit',
				'ObjectLit',
				'Optional',
				'OptionalArg',
				'OptionalNamedParam',
				'Or',
				'Overload',
				'Override',
				'PackageDecl',
				'PackageEmpty',
				'ParamCtor',
				'ParenExpr',
				'ParenLambdaExpr',
				'Parens',
				'Plain',
				'PlainMeta',
				'Positional',
				'PostDecr',
				'PostIncr',
				'PreDecr',
				'PreIncr',
				'Private',
				'Public',
				'RegexLit',
				'Required',
				'Rest',
				'ReturnExpr',
				'ReturnStmt',
				'SafeFieldAccess',
				'Shl',
				'ShlAssign',
				'Shr',
				'ShrAssign',
				'SimpleCtor',
				'SingleStringExpr',
				'Spread',
				'Static',
				'StaticFinalStmt',
				'StaticVarStmt',
				'Sub',
				'SubAssign',
				'SwitchExpr',
				'SwitchExprBare',
				'SwitchStmt',
				'SwitchStmtBare',
				'Ternary',
				'ThinArrow',
				'ThinParenLambdaExpr',
				'ThrowExpr',
				'ThrowStmt',
				'ToClause',
				'TryCatchStmt',
				'TryCatchStmtBare',
				'TryExpr',
				'TypeRef',
				'TypedCastExpr',
				'TypedefDecl',
				'UShr',
				'UShrAssign',
				'UsingDecl',
				'UsingWildDecl',
				'VarDecl',
				'VarExpr',
				'VarField',
				'VarForm',
				'VarMember',
				'VarMore',
				'VarSemiCondInitMember',
				'VarStmt',
				'VoidReturnExpr',
				'VoidReturnStmt',
				'WhileExpr',
				'WhileStmt'
			]
		};
		table.structureFieldHostKinds = ['Anon', 'ObjectLit'];
		table.nullableWrapperTypeNames = ['Null', 'Dynamic', 'Any'];
		table.memberTransparentWrapperTypeNames = ['Null'];
		table.nullSafetyDisableArg = 'Off';
		table.nonNullableTypeNames = ['Int', 'Float', 'Bool', 'UInt'];
		table.nullSafetyMetaName = '@:nullSafety';
		table.typedCastKinds = ['TypedCastExpr', 'ECheckTypeExpr'];
		table.checkedCastKind = 'TypedCastExpr';
		// `cast e` takes its result type from the CONTEXT; `cast(e, T)` / `(e : T)` carry their own.
		table.uncheckedCastKind = 'CastExpr';
		table.checkTypeKind = 'ECheckTypeExpr';
		table.nullSafeAccessKind = 'SafeFieldAccess';
		table.forceFieldAccessKind = 'ForceFieldAccess';
		table.indexAccessKind = 'IndexAccess';
		table.isExprKind = 'Is';
		table.isExprCall = 'Std.isOfType';
		table.isOperatorText = 'is';
		table.nullableOperandKinds = ['Call', 'FieldAccess', 'SafeFieldAccess'];
		table.notKind = 'Not';
		table.blockStmtKind = 'BlockStmt';
		table.breakStatementKind = 'BreakStmt';
		table.continueStatementKind = 'ContinueStmt';
		table.loopStatementKinds = ['ForStmt', 'WhileStmt'];
		table.doWhileLoopKinds = ['DoWhileStmt', 'DoWhileExpr'];
		table.intervalKind = 'Interval';
		table.whileStmtKind = 'WhileStmt';
		table.whileExprKind = 'WhileExpr';
		table.ltKind = 'Lt';
		table.postIncrKind = 'PostIncr';
		table.preIncrKind = 'PreIncr';
		table.andLowerPrecedenceKinds = [
			'Or',
			'Ternary',
			// `=>` and the two asymmetric operators bind tight on the left but take everything to
			// their right, so as the LEFT operand of `&&` they swallow it: `x -> b && c` is
			// `x -> (b && c)`. `HaxeAndLowerPrecedenceTest` derives this list from the parser.
			'Arrow',
			'ThinArrow',
			'In',
			// `cast` takes a whole expression: `cast a && b` is `cast (a && b)`.
			'CastExpr',
			'Assign',
			'AddAssign',
			'SubAssign',
			'MulAssign',
			'DivAssign',
			'ModAssign',
			'ShlAssign',
			'ShrAssign',
			'UShrAssign',
			'BitOrAssign',
			'BitAndAssign',
			'BitXorAssign',
			'NullCoalAssign',
			'BoolAndAssign',
			'BoolOrAssign'
		];
		table.andOperatorText = '&&';
		table.ternaryKind = 'Ternary';
		table.switchExpressionHostKinds = SWITCH_EXPRESSION_HOST_KINDS;
		// The switch hosts plus the three arrow-lambda bodies: a comparator written as
		// `(a, b) -> if (…) -1 else if (…) 1 else 0` is the established client shape, while a
		// `switch` in that slot is not — so the if-chain seam is a proper superset.
		// …plus the switch ARMS, taken from the one list that already names them. An arm's
		// value is delimited by the `:` that opens it and the `;` that ends it, exactly as a
		// `return` value is, and the formatter renders the ladder there under
		// `expressionIf: "next"`. The arm is reached through the expression-STATEMENT
		// wrapper, which `prefer-if-expression-chain` makes transparent only inside an arm —
		// a bare expression statement in a block is no host. `concat` copies, so the shared
		// static array is never aliased into the shape.
		// …plus an explicit `ParenExpr`. A ternary the author already wrapped in parens has the
		// same clean delimiters the other hosts do — the `(` and `)` themselves — so the ladder
		// goes INSIDE the existing parens and the rule adds no punctuation. This matters for a
		// ternary in operand position: `h - ih - (c ? a : b)` is legal as `h - ih - (if …)`, but
		// only WITH the parens; drop them and a following operand binds into the `else` branch
		// (`h - if (c) 1.0 else 2.0 - ih` compiles to a different value than the parenthesised
		// form). Requiring the parens in the SOURCE is what makes this host safe.
		table.ifExpressionChainHostKinds = SWITCH_EXPRESSION_HOST_KINDS.concat(
			['ThinArrow', 'ThinParenLambdaExpr', 'ParenLambdaExpr', 'ParenExpr']
		)
			.concat(BRANCH_SCOPE_KINDS);
		table.nullLiteralKind = 'NullLit';
		table.nullCoalesceKind = 'NullCoal';
		table.nullCoalesceOperatorText = '??';
		table.eqKind = 'Eq';
		table.notEqKind = 'NotEq';
		table.logicalAndKind = 'And';
		table.logicalOrKind = 'Or';
		table.newExprKind = 'NewExpr';
		table.fieldAccessKind = 'FieldAccess';
		table.returnStatementKind = 'ReturnStmt';
		table.conditionFirstChildKinds = ['IfStmt', 'IfExpr', 'WhileStmt', 'WhileExpr'];
		table.conditionLastChildKinds = ['DoWhileStmt', 'DoWhileExpr'];
		table.parenLambdaKind = 'ThinParenLambdaExpr';
		table.fnExprKind = 'FnExpr';
		table.namedFnExprKind = 'NamedFnExpr';
		table.typeAnnotationKinds = ['Named', 'Anon', 'Arrow', 'ArrowFn'];
		table.forStmtKind = 'ForStmt';
		table.iterationBindingKinds = ['ForStmt', 'ForExpr'];
		table.iterationValueBinderKinds = ['KeyValueBinder'];
		table.paramKinds = ['Required', 'Optional', 'Rest'];
		table.supertypeClauseKinds = ['ExtendsClause', 'ImplementsClause'];
		table.noBodyKind = 'NoBody';
		table.catchClauseKind = 'CatchClause';
		table.catchAllTypeNames = ['Dynamic', 'Any'];
		table.exceptionTypePath = 'haxe.Exception';
		table.rawThrowWrapperTypePath = 'haxe.ValueException';
		table.controlExitKinds = [
			'ThrowStmt',
			'ThrowExpr',
			'ReturnStmt',
			'VoidReturnStmt',
			'BreakStmt',
			'ContinueStmt',
			'BreakExpr',
			'ContinueExpr',
			'VoidReturnExpr'
		];
		table.caseLiteralKinds = ['IntLit', 'HexLit', 'FloatLit', 'BoolLit', 'NullLit'];
		table.tuplePatternDelimiters = { open: '[', close: ']' };
		table.visibilityContainerKinds = ['ClassDecl', 'ClassForm', 'AbstractClassDecl', 'AbstractDecl'];
		table.memberDeclKinds = ['VarMember', 'FinalMember', 'FnMember', 'FinalModifiedMember'];
		table.visibilityModifierKinds = ['Public', 'Private'];
		table.modifierOrderKinds = ['Override', 'Public', 'Private', 'Static', 'Inline', 'Final'];
		// EVERY modifier the grammar projects as a sibling, `abstract` and `overload` included.
		// `modifierOrderKinds` ranks six of them and is NOT this set: `overload` has no canonical
		// position, so ranking it would invent an order, while leaving it out of the membership set
		// ended every leading run it stood in. One list, written down in `HaxeNamingSupport`.
		table.modifierKinds = HaxeNamingSupport.MODIFIER_KINDS;
		table.finalModifierMemberKind = 'FinalModifiedMember';
		table.finalModifierRankKind = 'Final';
		table.fieldDeclKinds = ['VarMember', 'FinalMember'];
		// Every `HxFnBody` ctor, `UntypedBlockBody` and `CondBody` included: a consumer reads this
		// to tell a body child from a return-type child, so a missing ctor reads as a return type
		// (or, for a boundary scan, as no body at all).
		table.functionBodyKinds = ['BlockBody', 'UntypedBlockBody', 'ExprBody', 'NoBody', 'CondBody'];
		table.expressionBodyKinds = ['ExprBody'];
		table.enumAbstractDeclKind = 'EnumAbstractDecl';
		table.abstractFromClauseKind = 'FromClause';
		table.abstractToClauseKind = 'ToClause';
		// `@:coreType` abstracts (`Int`'s `to Float`) cast on through any clause; a plain one's clause allows no second cast
		table.transitiveCastTypeMetaNames = ['@:coreType', '@:transitive'];
		table.typeSelectedAbstractMetaName = '@:multiType';
		table.handUnifiedAbstractPaths = [
			'Void',
			'EnumValue',
			'Class',
			'Enum',
			'haxe.NotVoid',
			'haxe.FlatEnum',
			'haxe.Function',
			'haxe.Constructible'
		];
		table.enumAbstractMetaName = '@:enum';
		table.enumAbstractImplicitValues = { counting: ['Int', 'UInt'], naming: ['String'] };
		table.operatorOverloadMetaName = '@:op';
		table.commutativeOperatorMetaName = '@:commutative';
		table.signatureOverloadMetaName = '@:overload';
		table.overloadModifierKind = 'Overload';
		table.genericFunctionMetaName = '@:generic';
		table.dispatchedMemberMetaNames = ['@:from', '@:op', '@:arrayAccess', '@:resolve'];
		// The same three tokens `MemberWriteScan.carriesBuildMacro` matches, published so the
		// STRUCTURAL leading-run walk `unused-private` uses asks the grammar rather than spelling
		// them itself. `BuildMacroMetaSeamTest` fails if the two lists ever disagree.
		table.typeBuildMacroMetaNames = ['@:build', '@:autoBuild', '@:genericBuild'];
		// The one of those three that builds SUBTYPES rather than its carrier. `SymbolIndex` needs the
		// split because it reads the flags while climbing a chain upward; the file-scoped text scan does
		// not and keeps the union.
		table.descendantBuildMacroMetaNames = ['@:autoBuild'];
		table.retainedDeclMetaName = '@:keep';
		// `@:rtti` emits a `haxe.rtti.Rtti` description keyed by member NAME — a separate question from
		// `@:keep`, which only keeps the member alive.
		table.reflectedDeclMetaName = '@:rtti';
		// `@:access(T)` lets the CARRIER read T's privates. The mirror tag `@:allow(T)`, which lets T
		// read the carrier's, is a different question and is spelled by its ONE reader,
		// `RefactorSupport.carriesAllowGrant` — it was two until they drifted apart in what they
		// claimed about a hit. It has no seam here, and there is no hook to override either: that
		// function takes a source STRING and hardcodes the literal, so a grammar spelling the tag
		// differently gets Haxe's. Seaming it is the open item `RefShape` states; the literal in that
		// function is where the change goes, not this table.
		table.takesPrivateAccessMetaName = '@:access';
		table.waivesPrivacyMetaName = '@:privateAccess';
		table.forwardingDeclMetaName = '@:forward';
		table.implicitConstructorDeclMetaName = '@:structInit';
		// `@:nativeGen` is what makes a cs/java class a plain native type foreign code holds
		// directly — the Unity MonoBehaviour idiom. It is the marker, not `extends MonoBehaviour`:
		// Pony declares `@:nativeGen class Tooltip` with no superclass at all, and
		// `class PercentSize extends MonoBehaviour` with no annotation.
		table.nativeInteropDeclMetaName = '@:nativeGen';
		table.enumAbstractSyntax = { head: 'enum abstract {name}({under}) to {under}', bodyOpen: '{' };
		table.compileTimeTypeDeclKinds = ['TypedefDecl', 'AbstractDecl', 'EnumAbstractDecl'];
		table.indexValuedEnumAbstractUnderlyings = ['Int'];
		table.nameInertTypeMetaNames = [
			'@:forward',
			'@:forwardStatics',
			'@:transitive',
			'@:nullSafety',
			'@:enum',
			'@:noCompletion',
			'@:noDoc',
			'@:callable'
		];
		table.rawDynamicTypeName = 'Dynamic';
		table.bareConstructorTypeKinds = ['EnumDecl', 'EnumAbstractDecl'];
		// `trace` and the modules of the std root, `StdTypes` among them
		table.implicitValueNames = [
			'trace',
			'Any',
			'Array',
			'Class',
			'Date',
			'DateTools',
			'Enum',
			'EnumValue',
			'EReg',
			'IntIterator',
			'Lambda',
			'List',
			'Map',
			'Math',
			'Reflect',
			'Std',
			'String',
			'StringBuf',
			'StringTools',
			'Sys',
			'Type',
			'UInt',
			'UnicodeString',
			'Xml',
			'Void',
			'Float',
			'Int',
			'Null',
			'Bool',
			'Dynamic',
			'Iterator',
			'Iterable',
			'KeyValueIterator',
			'KeyValueIterable',
			'ArrayAccess'
		];
		table.runtimeTaggedTypeKinds = ['EnumDecl'];
		table.overrideModifierKind = 'Override';
		table.dynamicModifierKind = 'Dynamic';
		table.defaultVisibilityModifierText = 'private';
		table.externModifierKind = 'Extern';
		table.publicDefaultMetaNames = ['@:publicFields'];
		table.mutableFieldDeclKinds = ['VarMember'];
		table.voidReturnKind = 'VoidReturnStmt';
		table.valueReturnKinds = ['ReturnStmt', 'ReturnExpr'];
		table.throwKinds = ['ThrowStmt', 'ThrowExpr'];
		table.blockBodyKind = 'BlockBody';
		table.voidTypeName = 'Void';
		table.literalTypeNames = [
			'IntLit' => 'Int',
			'HexLit' => 'Int',
			'FloatLit' => 'Float',
			'BoolLit' => 'Bool',
			'SingleStringExpr' => 'String',
			'DoubleStringExpr' => 'String'
		];
		table.numericLiteralKinds = ['IntLit', 'FloatLit', 'HexLit'];
		table.coreValueTypes = {
			names: ['Bool', 'String', 'Int', 'Float'],
			widens: ['Int' => ['Float']],
			integer: 'Int',
			real: 'Float',
			boolean: 'Bool',
			integerMax: '2147483647',
			hexLiteralPrefix: '0x',
			classNames: ['String']
		};
		table.arithmeticKinds = ['Add', 'Sub', 'Mul', 'Div', 'Mod'];
		table.realArithmeticKinds = ['Div'];
		table.booleanOperatorKinds = ['Eq', 'NotEq', 'Lt', 'LtEq', 'Gt', 'GtEq', 'And', 'Or'];
		table.plainStructureFieldKinds = ['Required', 'Optional'];
		table.stringAffixTests = { module: 'StringTools', suffix: 'endsWith', prefix: 'startsWith' };
		table.iterableTypeName = 'Iterable';
		table.iterableElementTypeParams = ['Array' => 0, 'List' => 0, 'Iterable' => 0, 'Map' => 1];
		table.arrayLiteralKind = 'ArrayExpr';
		table.arrayTypeNames = ['Array'];
		table.objectLiteralKind = 'ObjectLit';
		table.trailingCommaHostKinds = ['ArrayExpr', 'ObjectLit', 'Anon', 'Call', 'NewExpr', 'MetaCall'];
		table.commaContainerKinds = ['ArrayExpr', 'ObjectLit', 'Call', 'NewExpr'];
		table.delimitedContainerKinds = [
			'ArrayExpr',
			'ObjectLit',
			'Call',
			'NewExpr',
			'BlockBody',
			'BlockStmt',
			'SwitchStmtBare',
			'SwitchExprBare'
		];
		table.mandatoryTrailingCommaChildKinds = ['ExtendsField'];
		table.negationKind = 'Neg';
		table.objectFieldKind = 'Field';
		table.sizeFieldNames = ['length'];
		table.positionMethodNames = ['substr', 'substring', 'charAt', 'charCodeAt', 'indexOf', 'lastIndexOf', 'hex'];
		table.additiveKinds = ['Add', 'Sub'];
		table.staticModifierKind = 'Static';
		table.inlineModifierKind = 'Inline';
		table.inlineConstantLiteralKinds = ['IntLit', 'HexLit', 'FloatLit', 'BoolLit'];
		table.constructorName = 'new';
		table.accessorMethodPrefixes = ['get_', 'set_'];
		table.conditionalMemberKind = 'Conditional';
		table.conditionalIfKeyword = '#if';
		table.conditionalElseKeywords = ['#else', '#elseif'];
		table.conditionalEndKeyword = '#end';
		table.condDeclPrefixKeywordKinds = ['EnumKw', 'AbstractKw', 'FinalKw'];
		// DERIVED, not written. The macro walks each ctor's own production to the terminals it
		// reaches and reports the ones that reach a `@:condRegionRaw` capture; `conditionalRegionKinds`
		// is the same walk widened by `@:condRegionCondition`, the atom every directive's condition is
		// captured as. Nothing here names a ctor, which is the point: the two earlier spellings of
		// this field both went stale in the fail-OPEN direction. A hand-written list of ten
		// `CondSplice*` names missed the three raw-capture ctors the grammar gained two days later
		// (`CondSpliceReturnStmt`, `CondSpliceReturnExpr`, `MetaCondStmt`), and every name-driven op
		// wrote silently over them for eighteen days; reading it as ctor-name PREFIXES closed those
		// and left the ctors that break the naming convention open — two already did, and the pin
		// guarding the list checked the same convention it did.
		table.opaqueCondRegionKinds = HaxeQueryWalker.opaqueCondRegionKinds();
		table.conditionalRegionKinds = HaxeQueryWalker.conditionalRegionKinds();
		table.orphanContinuationKinds = ['OrphanElseStmt'];
		table.condOperandRunKinds = ['CondSpliceOpExpr'];
		table.stringInterpIdentKind = 'Ident';
		table.stringInterpBlockKind = 'Block';
		table.stringInterpTextKind = 'Literal';
		table.reservedWords = HaxeIdentifierCase.KEYWORDS;

		table.declTypeChildKinds = ['Anon', 'TypeRef'];
		table.typeRefChildKinds = ['TypeRef'];
		table.anonTypeKind = 'Anon';
		table.defaultBranchKind = 'DefaultBranch';
		table.plainCasePatternKind = 'Plain';
		table.wildcardPatternName = '_';
		table.exprStatementKind = 'ExprStmt';
		table.nullCoalAssignKind = 'NullCoalAssign';
		table.operatorWriteKinds = [
			for (k in ASSIGN_KINDS) if (k != 'Assign' && k != 'NullCoalAssign') k
		].concat([
			'PreIncr',
			'PreDecr',
			'PostIncr',
			'PostDecr'
		]);
		table.numericOperatorKinds = [
			'Add', 'Sub', 'Mul', 'Div', 'Mod', 'Lt', 'Gt', 'LtEq', 'GtEq', 'BitAnd', 'BitOr', 'BitXor', 'Shl', 'Shr', 'UShr', 'Neg',
			'BitNot'
		];
		table.nullableNumericReturnCalls = ['Std.parseInt', 'Std.parseFloat'];
		table.stringLiteralKinds = ['SingleStringExpr', 'DoubleStringExpr'];
		table.interpolatingStringKinds = ['SingleStringExpr'];
		table.stringInterpInertSegmentKinds = ['Dollar', 'LoneDollar'];
		table.inertTextLiteralKinds = ['DoubleStringExpr', 'RegexLit'];
		table.stringLiteralDelimiters = ['DoubleStringExpr' => '"'];
		table.metadataNamePrefixes = ['@:', '@'];
		table.stringLiteralMethodReturns = [
			'split' => 'Array<String>',
			'substr' => 'String',
			'substring' => 'String',
			'charAt' => 'String',
			'toUpperCase' => 'String',
			'toLowerCase' => 'String',
			'toString' => 'String',
			'indexOf' => 'Int',
			'lastIndexOf' => 'Int'
		];
		table.staticMethodReturns = [
			'Context.resolvePath' => 'String',
			'Context.currentPos' => 'haxe.macro.Expr.Position',
			'Date.now' => 'Date',
			'File.append' => 'sys.io.FileOutput',
			// `Dynamic` is the ANSWER here, not a missing one: a rule that must know the receiver
			// type reads an untabled call as "unresolved" and degrades to report-only, while
			// `Dynamic` lets it apply its own `Dynamic` policy (`prefer-static-extension` drops the
			// site — an extension dispatches no method on a `Dynamic` value at runtime).
			'Reflect.field' => 'Dynamic',
			// `haxe.macro.Context.error` is declared `:Dynamic` (it never returns: it aborts the macro), so a
			// `macro` function's `return Context.error(…)` unifies with any other return it has.
			'Context.error' => 'Dynamic',
			// Reflection statics whose return is a plain `Array<String>` on every target — the
			// shapes real code iterates (`for (key in Reflect.fields(o))`), where the binder
			// carries no annotation and the element type is only readable from this return.
			'Reflect.fields' => 'Array<String>',
			'Type.getInstanceFields' => 'Array<String>',
			'Type.getClassFields' => 'Array<String>',
			'Type.getEnumConstructs' => 'Array<String>'
		];
		// `haxe.ds.Map`'s abstract wrappers carry no return annotation (`public inline
		// function exists(key:K) return this.exists(key);`), so no resolution scope can read
		// one. Both entries are the return their forwarded-to `haxe.Constraints.IMap` member
		// declares — `exists(k:K):Bool`, `remove(k:K):Bool` — fixed on every target. `get` is
		// absent on purpose: its `Null<V>` depends on the type argument.
		table.instanceMethodReturns = ['Map.exists' => 'Bool', 'Map.remove' => 'Bool'];
		// What sees whether an object HAS a field, not only its value: the field lists
		// and copies, `Json` and the `JsonPrinter` it delegates to, `Serializer` (a bare
		// `serialize` is the instance method on any receiver), `Std.string` printing an object, and a member read or test by
		// a name the call computes — each of which may tell a missing field from a null one.
		table.objectEnumeratingCalls = [
			'Reflect.fields' => -1,
			'Type.getInstanceFields' => -1,
			'Json.stringify' => -1,
			'JsonPrinter.print' => -1,
			'Reflect.copy' => -1,
			'Serializer.run' => -1,
			'serialize' => -1,
			'Std.string' => -1,
			'Reflect.field' => 1,
			'Reflect.getProperty' => 1,
			'Reflect.hasField' => 1
		];
		table.nullableIndexTypeNames = ['Map', 'StringMap', 'IntMap', 'ObjectMap', 'EnumValueMap', 'WeakMap'];
		table.mapAbstractTypeNames = ['Map'];
		table.nullableInstanceReturnCalls = [
			'Array.pop',
			'Array.shift',
			'List.pop',
			'List.first',
			'List.last',
			'Map.get',
			'StringMap.get',
			'IntMap.get',
			'ObjectMap.get',
			'EnumValueMap.get',
			'WeakMap.get'
		];
		table.nullableReturnMarkerTypes = ['Null'];
		table.nullableFlowExcludedCalls = [
			'Array.pop',
			'Array.shift',
			'List.pop',
			'List.first',
			'List.last',
			'Reflect.copy'
		];
		table.nullAssertionCalls = ['Assert.notNull'];
		table.assertTrueCalls = ['Assert.isTrue'];
		table.assertFalseCalls = ['Assert.isFalse'];
		table.mapExistsMethods = ['exists'];
		table.mapLiteralEntryKind = 'Arrow';
		table.finalClassMetaName = '@:final';
		// `@:generic` expands its class per type parameter, so there is no single class to hold a
		// static — Haxe rejects one with "A generic class can't have static fields" (verified 4.3.7).
		table.staticlessTypeMetaNames = ['@:generic'];
		table.plainClassDeclKind = 'ClassDecl';
		table.finalClassDeclKind = 'FinalDecl';
		table.typeDeclKinds = [
			'ClassDecl',
			'FinalDecl',
			'AbstractClassDecl',
			'AbstractDecl',
			'InterfaceDecl',
			'EnumDecl',
			'TypedefDecl'
		];
		table.interfaceDeclKinds = ['InterfaceDecl'];
		table.packageDeclKind = 'PackageDecl';
		table.grantsPrivateAccessMetaName = '@:allow';
		table.importLineTemplate = 'import %;';
		table.usingLineTemplate = 'using %;';
		table.typeNamesUpperInitial = true;
		table.qualifiedSubTypeByModulePath = true;
		table.packageSegmentPattern = '^[a-z_][A-Za-z0-9_]*$';
		table.publicModifierKind = 'Public';
		table.classDeclKinds = ['ClassDecl', 'AbstractClassDecl'];
		table.typeValueTypeNames = [
			'ClassDecl' => 'Class',
			'AbstractClassDecl' => 'Class',
			'InterfaceDecl' => 'Class',
			'EnumDecl' => 'Enum'
		];
		table.indexedElementTypeParams = ['Map' => 1, 'Array' => 0, 'Vector' => 0];
		// Haxe iteration semantics: `Array<T>` / `haxe.ds.Vector<T>` / `List<T>` yield `T`;
		// `Iterable<T>` yields `T` through the `iterator():Iterator<T>` it declares, and an
		// `Iterator<T>` is itself iterable yielding `T`. `Map<K, V>` is the odd one: its
		// `iterator()` yields the VALUES, so the element parameter is 1, not 0 (the keys need
		// the explicit `for (k => v in m)` form, whose KEY binder the element-type arm refuses).
		// OBLIGATION: this map answers the ELEMENT question, and the same entry now also types a
		// key-value loop's VALUE binder — so every name here must have `iterator()` element type
		// == `keyValueIterator()` value type. All six do; a container where they diverge does not
		// belong here, since the arm licenses NaN-unsound ordered-comparison rewrites.
		table.iterationElementTypeParams = [
			'Array' => 0,
			'Vector' => 0,
			'List' => 0,
			'Iterable' => 0,
			'Iterator' => 0,
			'Map' => 1
		];
		// the std types the two element maps describe, as an import or a toplevel name spells each (`Iterable` and
		// `Iterator` live in the `StdTypes` module, `List` and `Map` have a toplevel typedef beside their `haxe.ds` type)
		table.standardContainerPaths = [
			'Array' => ['Array'],
			'Vector' => ['haxe.ds.Vector'],
			'List' => ['List', 'haxe.ds.List'],
			'Iterable' => ['Iterable', 'StdTypes.Iterable'],
			'Iterator' => ['Iterator', 'StdTypes.Iterator'],
			'Map' => ['Map', 'haxe.ds.Map']
		];
		// `Array` and `haxe.ds.List` walk one index / node chain in both iterators; a map's
		// key-value iterator re-reads by key, so it diverges once the body removes an entry.
		table.valueIterationTypes = ['Array' => 'Array', 'List' => 'haxe.ds.List'];
		// equal to the value iteration — in values and order — on --interp, js and hxcpp for a map the
		// loop leaves unchanged (docs/decisions.md); `WeakMap` is not, its iterators are null off hxcpp
		table.keyedIterationTypes = [
			'Map' => 'haxe.ds.Map',
			'IntMap' => 'haxe.ds.IntMap',
			'StringMap' => 'haxe.ds.StringMap',
			'ObjectMap' => 'haxe.ds.ObjectMap',
			'EnumValueMap' => 'haxe.ds.EnumValueMap',
			'BalancedTree' => 'haxe.ds.BalancedTree'
		];
		// the classes a `Map` value may be: the ones its `@:from` conversions take, and the one it builds for enum keys
		table.keyedIterationHolders = ['Map' => ['IntMap', 'StringMap', 'ObjectMap', 'EnumValueMap']];
		table.importAliasKinds = ['ImportAliasDecl', 'ImportAliasInDecl'];
		table.untypedKinds = ['UntypedExpr'];
		table.casePatternBinderKinds = ['Capture'];
		// The Haxe extractor: `case f(_) => p:` evaluates `f` on the subject before
		// matching `p`. Reaching such an arm RUNS code, so a rewrite that newly makes
		// one reachable has to refuse it.
		table.casePatternExtractorKinds = ['Arrow'];
		table.aliasingDeclKinds = ['TypedefDecl', 'AbstractDecl', 'EnumAbstractDecl'];
		// Delimited expression slots, derived from the grammar productions:
		// `HxVarDecl.init` is `@:lead('=')` up to the decl's `;` / `,`;
		// `HxStatement.ReturnStmt` is `@:kw('return') @:trail(';')` and its
		// expression twin `HxExpr.ReturnExpr` parses its value at minPrec 0;
		// `HxExpr.ArrayExpr` is `@:lead('[') @:trail(']') @:sep(',')`;
		// `HxObjectFieldBody.value` is `@:lead(':')` inside the literal's
		// `@:lead('{') @:trail('}') @:sep(',')`; `HxNewExpr` closes its argument
		// Star with `)`. The `VarStmt`/`VarMember` type-annotation child and the
		// `NewExpr` type arguments project as type kinds (`Anon` / `Named`), never
		// as `ParenExpr`, so a whole-host listing stays exact.
		//
		// `HxStringSegment.Block` — the `${ … }` interpolation of a single-quoted
		// literal — is the same fact stated by a lead / trail pair: `@:lead('${')`
		// and `@:trail('}')` bound its ONE expression child, which `parseHxExpr`
		// reads at minPrec 0. The REAL compiler agrees by a different route: its
		// interpolation scanner slices the text between `${` and the brace-counted
		// matching `}` and parses that slice standalone, so nothing outside the
		// braces can bind into it. Dropping a paren pair inside the braces cannot
		// disturb that scan either — a parenthesis is none of the four characters
		// that scanner reacts to (`{`, `}`, `$`, a backslash) and no line break, so
		// it reads exactly the same text either way, whatever it makes of that text.
		//
		// `DollarBlockExpr` — the MACRO reification `${ … }` — is bound by the same
		// two hard tokens and is ABSENT, but only conservatively: `${ … }` is the
		// reification ESCAPE, its content is macro-TIME code, and `macro ${(e)}`
		// builds exactly what `macro ${e}` builds (no `EParenthesis` survives).
		// The pair that DOES reify is one written in the quoted region,
		// which `parenOpaqueSubtreeKinds` covers. Listing this kind is untaken work,
		// not a refused hazard.
		table.delimitedAllChildKinds = [
			'Block',
			'VarStmt',
			'FinalStmt',
			'VarExpr',
			'FinalExpr',
			'VarMember',
			'FinalMember',
			'ReturnStmt',
			'ReturnExpr',
			'ArrayExpr',
			'Field',
			'NewExpr'
		];
		// `Call`'s child 0 is the callee — an operand position, where parens can be
		// load-bearing (`(a ? b : c)(x)`); the arguments after it are delimited by
		// `(` / `,` / `)`. The assignment family's child 0 is likewise the target,
		// while the right-hand side is the right operand of a prec-0
		// right-associative operator, i.e. parsed at minPrec 0 up to the enclosing
		// terminator. `IndexAccess` is the same shape one bracket over: child 0 is the
		// RECEIVER, an operand position (`(a ? b : c)[i]` needs its parens), while the
		// index at child 1 is bounded by the `[` and `]` themselves and parses at
		// minPrec 0 — `arr[untyped i]`, `arr[cast i]`, `arr[if (c) 1 else 2]` and
		// `arr[@:privateAccess q.v]` all compile bare, the `]` ending each of them.
		// `Interval`, `Arrow` and the other infix kinds are deliberately absent: their
		// operands parse above minPrec 0 and re-associate on unwrap — a map-literal key
		// `[(a ? b : c) => d]` bare is `Unexpected =>`, which is why an index slot and
		// an `=>` operand are not the same question.
		table.delimitedTailChildKinds = ['Call', 'IndexAccess'].concat(ASSIGN_KINDS);
		// `macro final w = 1` re-enters the unrestricted expression parse, where the
		// declaration's `, b = 2` continuation reaches past the separator that ends
		// the slot — so a paren around one is load-bearing while it is the last thing
		// inside them.
		table.separatorGreedyExprKinds = ['VarExpr', 'FinalExpr'];
		// `$a{exprs}` splices its array into the surrounding argument / element list
		// only when nothing wraps it, so a paren around one changes the built call's
		// ARITY with no syntax error. All `$x{…}` forms share this kind.
		table.spliceSensitiveExprKinds = ['DollarReifExpr'];
		// Provably tighter than `?:`, so a paren around one as a ternary condition is
		// redundant. Fail-closed: the loose / right-greedy kinds (assignment, ternary,
		// arrow, `untyped`/`macro`/metadata, block-like `if`/`switch` exprs) are absent,
		// so they keep their parens. Object literals (leading-`{` ambiguity) and casts
		// (rare) are conservatively omitted too.
		table.ternaryConditionUnwrapKinds = [
			'Add',
			'Sub',
			'Mul',
			'Div',
			'Mod',
			'Eq',
			'NotEq',
			'Lt',
			'LtEq',
			'Gt',
			'GtEq',
			'And',
			'Or',
			'NullCoal',
			'BitAnd',
			'BitOr',
			'BitXor',
			'Shl',
			'Shr',
			'UShr',
			'Interval',
			'Is',
			'Neg',
			'Not',
			'BitNot',
			'PreIncr',
			'PreDecr',
			'PostIncr',
			'PostDecr',
			'IdentExpr',
			'IntLit',
			'FloatLit',
			'HexLit',
			'BoolLit',
			'NullLit',
			'SingleStringExpr',
			'DoubleStringExpr',
			'RegexLit',
			'Call',
			'FieldAccess',
			'SafeFieldAccess',
			'ForceFieldAccess',
			'IndexAccess',
			'ArrayExpr',
			'NewExpr'
		];
		// Self-delimiting content: no operator outside can bind into it. `IdentExpr`
		// covers `this`. `SingleStringExpr` projects its segments and `${…}`
		// interpolations as children — all sealed inside the quotes, so they are not
		// re-examined. `RegexLit` is out: its closing `/` welds onto a following `/`.
		table.atomExprKinds = [
			'IdentExpr',
			'IntLit',
			'FloatLit',
			'HexLit',
			'BoolLit',
			'NullLit',
			'SingleStringExpr',
			'DoubleStringExpr'
		];
		// A transparent link: `a.b.c` is one atom, while `f().b` / `arr[i].b` /
		// `a?.b` are not — their unlisted child stops the chain.
		table.atomChainKinds = ['FieldAccess'];
		// Every operator the Pratt set computes a value with and nothing else. The mutating
		// halves are absent by construction: the compound assigns, `Assign` and the four
		// increment / decrement ctors all store. `Is` and `BitNot` are in because `a is B` and
		// `~a` are reads; each stood in exactly ONE of the two hand-written tables this field
		// replaced, which is the drift a single declaration ends.
		table.pureOperatorKinds = [
			'Add',
			'Sub',
			'Mul',
			'Div',
			'Mod',
			'And',
			'Or',
			'Eq',
			'NotEq',
			'Lt',
			'Gt',
			'LtEq',
			'GtEq',
			'BitAnd',
			'BitOr',
			'BitXor',
			'Shl',
			'Shr',
			'UShr',
			'NullCoal',
			'Neg',
			'Not',
			'BitNot',
			'Is',
			'Ternary'
		];
		// Haxe's postfix / allocation primaries: nothing outranks a call, a field read, an
		// index or a `new`, so none of them needs wrapping when substituted. `SafeFieldAccess`
		// and `ForceFieldAccess` are deliberately absent — they bind just as tightly, but
		// `(a?.b).c` and `a?.b.c` cover different spans with the null short-circuit, so the
		// parens there are meaning and not precedence.
		table.maximalPrecedenceRootKinds = ['Call', 'FieldAccess', 'IndexAccess', 'NewExpr'];
		// One tier each, left-associative, so `(a * b) / c` and `a * b / c` parse
		// alike. `Mod` is deliberately in NO family: Haxe binds `%` TIGHTER
		// than `*` and `/` (`2 * 7 % 4` is 6), and the grammar models that as its own
		// prec-11 tier, so `%` never shares a tier with another operator. A single-member
		// `['Mod']` family would be sound (`(a % b) % c` re-parses to the tree it already
		// had) but stays out of scope here.
		table.leftAssociativeBinaryFamilies = [['Mul', 'Div'], ['Add', 'Sub']];
		// The prec-5 tier's two VALUE comparisons apiece. `Is` (a type on the right, and its own
		// tier above every binary operator) and `Interval` (one tier looser, and a `...` that abuts
		// numeric-literal / field-access `.` lexing) are deliberately not hosts.
		table.comparisonOperandHostKinds = ['Eq', 'NotEq', 'Lt', 'LtEq', 'Gt', 'GtEq'];
		// The arithmetic core plus the POSTFIX in/decrements: tiers 9-11 and the
		// postfix chain links, strictly tighter than a comparison here AND in every
		// C-family language, so the drop is right on both readings. `PostIncr` /
		// `PostDecr` are what `while ((a++) < 36)` needs; their own `++` / `--`
		// token closes the content, so no greedy tail can reach past the pair, and
		// their leftmost token is the OPERAND, so the leading-minus rule has nothing
		// to refuse. The PREFIX `PreIncr` / `PreDecr` are equally provable and stay
		// off on READABILITY grounds — bare, `(++b) < 36` reads `++b < 36` — but by
		// mere absence from this ROOT whitelist, not by the gate that keeps `Neg` out:
		// `unaryMinusKinds` refuses a leading minus at ANY depth and has no prefix
		// in/decrement analogue, so `(--b * c) > d` is a `Mul` root and still drops.
		// The BITWISE tier (7) is out for CORRECTNESS — C binds
		// `& | ^` LOOSER than `==`, so `(x & m) != 0` reads differently there once
		// the pair is gone. The SHIFT tier (8) binds tighter than a comparison in C
		// exactly as it does here and WOULD be provable; it is out on READABILITY
		// alone, since a shift operand is habitually parenthesized. Atoms are the
		// `atoms` arm's; the two converge over `lint --fix` passes. `Neg` USED to be
		// here as a root; `unaryMinusKinds` now owns the whole leading-minus rule,
		// so listing it as well would be a whitelist entry nothing can pass.
		table.comparisonOperandUnwrapKinds = ['Add', 'Sub', 'Mul', 'Div', 'Mod', 'PostIncr', 'PostDecr'];
		// The prec-9 tier. NOT the multiplicative one above it: Haxe binds `%` tighter
		// than `*` and `/`, but C makes the three ONE tier, so a bare `a * b % c` reads
		// `(a * b) % c` to a C-trained eye and the pair in `a * (b % c)` is what makes
		// the two readings agree. Bitwise and shift are no hosts either — not for
		// correctness (`(a * b) & c` bare re-parses the same here and in C) but on the
		// READABILITY ground that keeps shifts off the comparison whitelist.
		table.additiveOperandHostKinds = ['Add', 'Sub'];
		// Tiers 10 and 11 and the POSTFIX in/decrements — strictly tighter than `+` / `-`
		// here AND in C, so the drop is right on both readings; `(a++) + b` bare is the
		// tree it already had. The SAME tier (`Add` / `Sub`) is out for CORRECTNESS:
		// `a + (b - c)` bare is `(a + b) - c`, a different value. `Neg` is provable and
		// out on READABILITY alone (`a - (-b)` bare reads `a - -b`). The PREFIX
		// `PreIncr` / `PreDecr` are off on that same ground (`a - (--b)` bare reads
		// `a - --b`) but only as a ROOT — `Neg` has `unaryMinusKinds` refusing it at any
		// depth, a prefix in/decrement has no such gate, so `a - (--b * c)` still drops.
		// Only the POSTFIX spelling puts the operand first.
		// Everything looser re-associates outward and is excluded by construction.
		table.additiveOperandUnwrapKinds = ['Mul', 'Div', 'Mod', 'PostIncr', 'PostDecr'];
		// Everything whose extent runs to the enclosing bracket. Probed one shape
		// apiece: each of these swallows a trailing `- d` that a parenthesis would
		// have kept out (`x + b * cast c - d` is `x + b * cast (c - d)`). `MetaExpr`
		// is here on the COMPILER's answer, not this parser's: the compiler binds the
		// annotation to the immediate primary, this grammar over everything that
		// follows. The two asymmetric
		// operators `->` and `in` are here too: their root binds tighter than any
		// other binary operator on the LEFT, yet `(x -> b) + c` bare is
		// `x -> (b + c)`. Deliberately absent:
		// the brace- and bracket-closed forms (`switch`, a block, an object or
		// array literal, `cast(e, T)`, `(e : T)`, `macro class`, `new T(…)`) and
		// the tight unary prefixes (`-`, `!`, `~`, `++`, `--`), none of which reach
		// past their own last token.
		table.rightGreedyExprKinds = [
			'ThinArrow',
			'In',
			'UntypedExpr',
			'MacroExpr',
			'MetaExpr',
			'CastExpr',
			'FnExpr',
			'NamedFnExpr',
			'ThinParenLambdaExpr',
			'ParenLambdaExpr',
			'ThrowExpr',
			'ReturnExpr',
			'InlineExpr',
			'IfExpr',
			'ForExpr',
			'ForReifExpr',
			'WhileExpr',
			'TryExpr',
			'Ternary'
		];
		// `a + (-b * c)` bare reads `a + -b * c` — a `Mul` root over a leading
		// minus, the same defect a bare `Neg` root is excluded for.
		table.unaryMinusKinds = ['Neg'];
		// `@:m expr` — the annotation binds to whatever `expr` starts with, so a pair
		// on that left edge is holding it there. `MetaCall` is the annotation node
		// INSIDE this one, not a prefix of anything.
		table.prefixAnnotationKinds = ['MetaExpr'];
		// A direct paren child of these is grammar syntax (`case X if (g)`) or an
		// idiom the project keeps out of scope (a second `switch` subject pair,
		// metadata arguments).
		table.parenRequiredHostKinds = [
			'CaseBranch',
			'SwitchStmt',
			'SwitchStmtBare',
			'SwitchExpr',
			'SwitchExprBare',
			'MetaCall',
			'MetaExpr'
		];
		// Inside a `macro` quotation a paren reifies as `EParenthesis`; inside a case
		// pattern the syntax is matched structurally, not by expression precedence.
		table.parenOpaqueSubtreeKinds = ['MacroExpr', 'Plain'];
		return table;
	}

}
