import unittest
import json
from pathlib import Path
import tempfile
from unittest.mock import patch
from scripts.evaluate_evidence_selector import grade
from scripts.audit_mobile_release import audit_android_release, main as audit_release, media_diagnostics


BACKUP_SETTINGS = ('android:allowBackup="false" android:fullBackupContent="false" '
                   'android:dataExtractionRules="@xml/data_extraction_rules"')
BACKUP_EXCLUDES = ''.join(
    f'<exclude domain="{domain}" path="."/>'
    for domain in ('root', 'file', 'database', 'sharedpref', 'external')
)
BACKUP_RULES = (f'<data-extraction-rules><cloud-backup>{BACKUP_EXCLUDES}</cloud-backup>'
                f'<device-transfer>{BACKUP_EXCLUDES}</device-transfer></data-extraction-rules>')


def write_manifest(evidence, permission='', component='', *, backup=BACKUP_SETTINGS):
    (evidence / 'AndroidManifest.xml').write_text(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
        'package="org.carenotebook.care_notebook">'
        '<uses-permission android:name="android.permission.RECORD_AUDIO" />'
        f'{permission}<application {backup}>{component}</application></manifest>',
        encoding='utf-8',
    )


def write_android_evidence(evidence):
    write_manifest(evidence)
    (evidence / 'runtime-dependencies.txt').write_text('androidx.core:core:1.17.0\n', encoding='utf-8')
    (evidence / 'runtime-local-files.txt').write_text('', encoding='utf-8')
    rules = evidence / 'backup-resources' / 'xml' / 'data_extraction_rules.xml'
    rules.parent.mkdir(parents=True)
    rules.write_text(BACKUP_RULES, encoding='utf-8')
    return rules


class ReleaseAuditTests(unittest.TestCase):
    def test_android_release_checks_merged_permissions_and_resolved_ad_dependencies(self):
        with tempfile.TemporaryDirectory() as temp:
            evidence = Path(temp)
            runtime = evidence / 'runtime-dependencies.txt'
            local_runtime = evidence / 'runtime-local-files.txt'
            write_android_evidence(evidence)
            safe_runtime = runtime.read_text(encoding='utf-8')
            self.assertEqual(audit_android_release(evidence)['permissions'], ['android.permission.RECORD_AUDIO'])
            for node, name in [
                ('uses-permission', 'com.google.android.gms.permission.AD_ID'),
                ('uses-permission-sdk-23', 'android.permission.INTERNET'),
                ('uses-permission', 'android.permission.READ_CONTACTS'),
            ]:
                with self.subTest(permission=name):
                    write_manifest(evidence, f'<{node} android:name="{name}" />')
                    with self.assertRaisesRegex(ValueError, name):
                        audit_android_release(evidence)

            write_manifest(evidence, component='<meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" />')
            with self.assertRaisesRegex(ValueError, 'com.google.android.gms.ads.APPLICATION_ID'):
                audit_android_release(evidence)

            write_manifest(evidence)
            runtime.write_text(safe_runtime + 'com.google.android.gms:play-services-ads-api:25.5.0\n', encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'play-services-ads-api'):
                audit_android_release(evidence)

            runtime.write_text(safe_runtime, encoding='utf-8')
            for filename in ('compatibility.jar', 'vendored.aar', 'classes'):
                with self.subTest(local_file=filename):
                    local_runtime.write_text(filename, encoding='utf-8')
                    with self.assertRaisesRegex(ValueError, f'Unapproved.*{filename}'):
                        audit_android_release(evidence)

            local_runtime.unlink()
            with self.assertRaisesRegex(ValueError, 'Missing Android release local file inventory'):
                audit_android_release(evidence)

    def test_android_release_rejects_missing_or_enabled_backup_settings(self):
        with tempfile.TemporaryDirectory() as temp:
            evidence = Path(temp)
            write_android_evidence(evidence)
            for name, expected, changed in [
                ('allowBackup', 'false', 'true'),
                ('fullBackupContent', 'false', 'true'),
                ('dataExtractionRules', '@xml/data_extraction_rules', '@xml/other_rules'),
            ]:
                for replacement in ('', f'android:{name}="{changed}"'):
                    with self.subTest(attribute=name, replacement=replacement):
                        backup = BACKUP_SETTINGS.replace(f'android:{name}="{expected}"', replacement)
                        write_manifest(evidence, backup=backup)
                        with self.assertRaisesRegex(ValueError, name):
                            audit_android_release(evidence)

    def test_android_release_checks_default_and_qualified_backup_rules(self):
        with tempfile.TemporaryDirectory() as temp:
            evidence = Path(temp)
            rules = write_android_evidence(evidence)
            override = rules.parent.with_name('xml-v31') / rules.name
            override.parent.mkdir()
            for altered, problem in [
                (BACKUP_RULES.replace(f'<device-transfer>{BACKUP_EXCLUDES}</device-transfer>', ''), 'device-transfer'),
                (BACKUP_RULES.replace('<exclude domain="database" path="."/>', '', 1), 'cloud-backup'),
                (BACKUP_RULES.replace('<device-transfer>', '<device-transfer><include domain="root" path="."/>'),
                 'device-transfer'),
            ]:
                with self.subTest(problem=problem):
                    override.write_text(altered, encoding='utf-8')
                    with self.assertRaisesRegex(ValueError, f'xml-v31.*{problem}'):
                        audit_android_release(evidence)
            override.write_text(BACKUP_RULES, encoding='utf-8')
            self.assertEqual(audit_android_release(evidence)['status'], 'passed')
            rules.unlink()
            with self.assertRaisesRegex(ValueError, 'Missing merged Android backup rules'):
                audit_android_release(evidence)

    def test_model_json_requires_exact_keys_unique_ids_and_all_conditions(self):
        self.assertTrue(grade('{"evidence_ids":["b","a"]}', ['a', 'b'])['exact_ids'])
        for text in ['{"evidence_ids":["a"]}', '{"evidence_ids":["a","a"]}',
                     '{"evidence_ids":["a","b"],"advice":"unsafe"}',
                     'prefix {"evidence_ids":["a","b"]}', 'null', '[]']:
            self.assertFalse(grade(text, ['a', 'b'])['exact_ids'])

    def test_saved_native_outputs_are_not_marked_as_new_device_or_quality_approval(self):
        report = media_diagnostics()
        self.assertIn('archived', report['execution'])
        self.assertFalse(report['quality_gate_passed'])
        self.assertGreater(report['groups']['speech']['edits'], 0)
        self.assertGreater(report['groups']['ocr']['cases'], 0)

    def test_android_scope_defers_ios_without_granting_medical_approval(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'audit.json'
            with patch('sys.argv', ['audit', '--output', str(output)]), \
                 patch('scripts.audit_mobile_release.audit_package', return_value={'sources': [], 'pages': []}), \
                 patch('scripts.audit_mobile_release.media_diagnostics', return_value={}):
                audit_release()
            report = json.loads(output.read_text(encoding='utf-8'))
        self.assertEqual(report['release_platforms'], ['android'])
        self.assertEqual(report['deferred_platforms'], ['ios'])
        self.assertEqual(report['android_release']['status'], 'not_checked')
        self.assertFalse(report['medical_release_gate_result'])
        self.assertTrue(report['blockers'])
        self.assertFalse(any('ios' in blocker.lower() for blocker in report['blockers']))


if __name__ == '__main__':
    unittest.main()
