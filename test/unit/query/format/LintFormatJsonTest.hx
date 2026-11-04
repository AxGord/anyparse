package unit.query.format;

import anyparse.check.Check.Violation;
import anyparse.check.common.design.threads.LongLockExplain.LongLockReason;
import anyparse.query.format.LintFormat;
import anyparse.runtime.Span;

/**
 * What `lint --format json` prints is a contract of its readers, so its bytes are spelled here, in the layout a native
 * JSON writer indents by two spaces, key order and all.
 */
class LintFormatJsonTest extends Test {

	private static final SOURCE: Map<String, String> = ['a.hx' => 'one\ntwo\n'];
	private static final FINDING: Violation = {
		file: 'a.hx',
		span: new Span(4, 7),
		rule: 'r',
		severity: Warning,
		message: 'say "x"'
	};
	private static final FINDING_TEXT: String = '{\n  "file": "a.hx",\n  "line": 2,\n  "col": 1,\n  "endLine": 2,\n  "endCol": 4,\n'
		+ '  "severity": "warning",\n  "rule": "r",\n  "message": "say \\"x\\""\n}';

	public function testNoFinding(): Void {
		Assert.equals('[]', LintFormat.json([], SOURCE));
	}

	public function testAFinding(): Void {
		Assert.equals('[\n  ${FINDING_TEXT.split('\n').join('\n  ')}\n]', LintFormat.json([FINDING], SOURCE));
	}

	public function testNoSpanIsNullCoordinates(): Void {
		final text: String = LintFormat.json([
			{
				file: 'a.hx',
				span: null,
				rule: 'r',
				severity: Info,
				message: 'm'
			}
		], SOURCE);
		Assert.stringContains('"line": null,\n    "col": null,\n    "endLine": null,\n    "endCol": null,\n    "severity": "info"', text);
	}

	public function testAddressAndDataFollowTheFinding(): Void {
		final finding: Violation = {
			file: 'a.hx',
			span: new Span(0, 3),
			rule: 'r',
			severity: Error,
			message: 'm',
			data: {
				family: 'f',
				member: 'T.m',
				subject: 's',
				chain: ['x', 'y'],
				repeatedBy: [{ member: 'T.n', at: 'for' }]
			}
		};
		Assert.equals(
			'[\n  {\n    "file": "a.hx",\n    "line": 1,\n    "col": 1,\n    "endLine": 1,\n    "endCol": 4,\n    "severity": "error",\n'
			+ '    "rule": "r",\n    "message": "m",\n    "data": {\n      "family": "f",\n      "function": "T.m",\n'
			+ '      "subject": "s",\n      "chain": [\n        "x",\n        "y"\n      ],\n      "repeatedBy": [\n        {\n'
			+ '          "function": "T.n",\n          "at": "for"\n        }\n      ]\n    },\n    "address": "FnMember:m"\n  }\n]',
			LintFormat.json([finding], SOURCE, _ -> 'FnMember:m')
		);
	}

	public function testAnExplainWithNoReportIsANullEnvelope(): Void {
		Assert.equals('{\n  "findings": [],\n  "longLocks": null\n}', LintFormat.json([], SOURCE, null, { report: null }));
	}

	public function testAnExplainedReport(): Void {
		final reason: LongLockReason = {
			kind: SpansBlocking,
			file: 'a.hx',
			span: new Span(4, 7),
			holder: 'T.f',
			call: 'T.g',
			chain: ['T.g', 'sink'],
			via: null,
			unresolved: [],
			errorPath: 'a.hx:9'
		};
		final blind: LongLockReason = {
			kind: Blind,
			file: 'a.hx',
			span: null,
			holder: 'T.h',
			call: null,
			chain: [],
			via: null,
			unresolved: [{ name: 'u', span: new Span(0, 1) }],
			errorPath: null
		};
		Assert.equals(
			'{\n  "findings": [],\n  "longLocks": {\n    "long": [\n      {\n        "lock": "L",\n        "reasons": [\n          {\n'
			+ '            "file": "a.hx",\n            "line": 2,\n            "col": 1,\n            "function": "T.f",\n'
			+ '            "kind": "spans-blocking",\n            "call": "T.g",\n            "chain": [\n              "T.g",\n'
			+ '              "sink"\n            ],\n            "via": null,\n            "errorPath": "a.hx:9"\n          },\n'
			+ '          {\n            "file": "a.hx",\n            "line": null,\n            "col": null,\n            "function": '
			+ '"T.h",\n            "kind": "blind",\n            "unresolved": [\n              {\n                "name": "u",\n'
			+ '                "line": 1,\n                "col": 1\n              }\n            ]\n          }\n        ],\n        '
			+ '"circular": 2,\n        "aside": null\n      }\n    ],\n    "mainShort": [\n      {\n        "file": "a.hx",\n        '
			+ '"line": 1,\n        "col": 1,\n        "lock": "M",\n        "function": "T.k",\n        "quiet": true\n      }\n    ],\n'
			+ '    "dominated": [\n      {\n        "lock": "D",\n        "by": [\n          "L"\n        ]\n      }\n    ]\n  }\n}',
			LintFormat.json([], SOURCE, null, {
				report: {
					long: [
						{
							lock: 'L',
							reasons: [reason, blind],
							circular: 2,
							aside: null
						}
					],
					mainShort: [
						{
							lock: 'M',
							file: 'a.hx',
							span: new Span(0, 1),
							holder: 'T.k',
							quiet: true
						}
					],
					dominated: [{ lock: 'D', by: ['L'] }]
				}
			})
		);
	}

}
