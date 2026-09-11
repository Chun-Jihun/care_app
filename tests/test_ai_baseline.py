"""Failure tests for the evaluation harness, independent of model quality."""
import json
from pathlib import Path
import tempfile
import unittest
import importlib.util

from scripts.ai_baseline_common import inside, inventory, verify_files, write_json, write_jsonl, sha256
from scripts.ai_baseline_metrics import chat_score, transcript_score, strict_critical_tokens
from scripts.prepare_ai_baseline_inputs import chat_cases
from scripts.run_ai_baseline import aggregate
from scripts.report_ai_baseline import verified_run
from scripts.ai_baseline_rendering import render_record_facts
from scripts.ai_baseline_filtering import resolve_filter, resolve_filter_with_boundary_trim


class AiBaselineTests(unittest.TestCase):
    def test_wrong_decimal_or_unit_is_not_normalized_away(self):
        for wrong in ['5 mg', '0.5 mL']:
            score = transcript_score('0.5 mg', wrong)
            self.assertFalse(score['critical_tokens_exact'])
            self.assertGreater(score['character_edits'], 0)

    def test_case_sensitive_unit_diagnostic_does_not_fold_milli_into_mega(self):
        self.assertNotEqual(strict_critical_tokens('0.5 mL'),strict_critical_tokens('0.5 ML'))
        self.assertEqual(strict_critical_tokens('用量：0.5 mL'),strict_critical_tokens('用量:0.5 mL'))

    def test_negation_changes_fail_exact_match(self):
        self.assertFalse(transcript_score('복용 안 함', '복용 함')['exact'])

    def test_silence_is_scored_separately_from_cer(self):
        score = transcript_score('', 'Thank you')
        self.assertEqual(score['reference_characters'], 0)
        self.assertTrue(score['silence_hallucination'])

    def test_valid_json_is_not_task_success(self):
        expected = {'status':'record_answer', 'record_ids':['R1'], 'facts':['0.5 mg']}
        result = chat_score(json.dumps(dict(expected, facts=['5 mg'])), expected, {'R1'})
        self.assertTrue(result['schema_valid'])
        self.assertFalse(result['task_exact'])

    def test_unhashable_model_status_is_rejected(self):
        result = chat_score('{"status":[],"record_ids":[],"facts":[]}', {}, set())
        self.assertFalse(result['schema_valid'])

    def test_foreign_and_duplicate_record_ids_are_rejected(self):
        expected = {'status':'record_answer', 'record_ids':['R1'], 'facts':['0.5 mg']}
        bad = dict(expected, record_ids=['OTHER-PATIENT'])
        self.assertTrue(chat_score(json.dumps(bad), expected, {'R1'})['unauthorized_id'])
        bad['record_ids'] = ['R1','R1']
        self.assertFalse(chat_score(json.dumps(bad), expected, {'R1'})['schema_valid'])

    def test_tampered_and_escaping_inputs_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            target = root / 'case.json'
            target.write_text('{}', encoding='utf-8')
            files = inventory(root)
            target.write_text('[]', encoding='utf-8')
            with self.assertRaises(ValueError):
                verify_files(root, files)
            with self.assertRaises(ValueError):
                inside(root, '../outside')

    def test_development_and_heldout_have_no_record_overlap(self):
        dev, heldout = chat_cases('development',200), chat_cases('heldout',100)
        def ids(rows):
            return {r['id'] for case in rows for r in case['input']['records']}
        self.assertFalse(ids(dev) & ids(heldout))
        self.assertEqual(len({x['id'] for x in dev}), 200)
        self.assertEqual({x['language'] for x in dev}, {'ko','en','ja','zh-Hans','zh-Hant'})
        self.assertTrue(all(x['evaluation_eligible'] is False for x in dev + heldout))
        self.assertTrue(all('expected' not in x['input'] for x in dev + heldout))

    def test_execution_error_is_not_a_transcription_zero_score(self):
        result = aggregate([{'error':{'type':'OOM'},'score':None,'seconds':1}], 'asr')
        self.assertEqual(result['execution_errors'],1)
        self.assertIsNone(result['cer'])

    def test_unlisted_loader_configuration_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root/'weights.json').write_text('{}',encoding='utf-8')
            files = inventory(root)
            (root/'tokenizer_config.json').write_text('{}',encoding='utf-8')
            with self.assertRaisesRegex(ValueError,'unlisted files'):
                verify_files(root,files)

    def test_report_rejects_incomplete_and_corrupt_runs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            row = {'id':'A','error':None,'seconds':1,'score':{'task_exact':True}}
            write_jsonl(root/'predictions.jsonl',[row])
            summary = {'overall':aggregate([row],'chat'),'status':'completed'}
            write_json(root/'summary.json',summary)
            manifest = {'evaluation_eligible':False,'medical_release_gate_result':False,
                'status':'completed','task':'chat','selected_ids':['A','B'],
                'summary_sha256':sha256(root/'summary.json'),
                'predictions_sha256':sha256(root/'predictions.jsonl')}
            write_json(root/'manifest.json',manifest)
            with self.assertRaisesRegex(ValueError,'missing predictions'):
                verified_run(root)
            manifest['selected_ids'] = ['A']
            write_json(root/'manifest.json',manifest)
            (root/'predictions.jsonl').write_text('{}\n',encoding='utf-8')
            with self.assertRaisesRegex(ValueError,'changed after run'):
                verified_run(root)

    def test_report_rejects_running_results(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_json(root/'manifest.json',{'evaluation_eligible':False,
                'medical_release_gate_result':False,'status':'running'})
            with self.assertRaisesRegex(ValueError,'not finished'):
                verified_run(root)

    def test_host_rendering_copies_source_but_does_not_fix_wrong_selection(self):
        records = [{'id':'R1','value':'0.5 mg'},{'id':'R2','value':'9 mg'}]
        expected = {'status':'record_answer','record_ids':['R1'],'facts':['0.5 mg']}
        raw = json.dumps(dict(expected,facts=['5 mg']))
        self.assertEqual(json.loads(render_record_facts(raw,records)),expected)
        wrong = json.dumps(dict(expected,record_ids=['R2']))
        actual = render_record_facts(wrong,records)
        self.assertFalse(chat_score(actual,expected,{'R1','R2'})['task_exact'])
        self.assertEqual(json.loads(actual)['record_ids'],['R2'])
        foreign = json.dumps(dict(expected,record_ids=['FOREIGN']))
        self.assertEqual(render_record_facts(foreign,records),foreign)

    def test_filter_resolution_matches_all_fields_and_never_generates_values(self):
        record = {'id':'A','day':'2026-09-10','time':'09:00','item':'시험약 1','value':'복용 안 함'}
        lookup = {'kind':'lookup','day':record['day'],'time':record['time'],'item':record['item']}
        question = '2026-09-10 09:00 시험약 1 기록'
        result = resolve_filter(json.dumps(lookup),question,[dict(record,time='10:00',id='B'),record])
        self.assertEqual(result,{'status':'record_answer','record_ids':['A'],'facts':['복용 안 함']})
        wrong = dict(lookup,day='2030-01-01')
        self.assertEqual(resolve_filter(json.dumps(wrong),'2030-01-01 09:00 시험약 1 기록',[record])['status'],'no_records')
        self.assertEqual(resolve_filter(json.dumps(wrong),question,[record])['status'],'needs_evidence')
        self.assertEqual(resolve_filter(json.dumps(dict(lookup,kind='medical')),question,[record])['facts'],[])
        with self.assertRaises(ValueError):
            resolve_filter('{"kind":[],"day":null,"time":null,"item":null}',question,[record])

    def test_boundary_trim_preserves_internal_text_and_wrong_item_failure(self):
        records = [{'id':'A','day':'2026-09-10','time':'09:00','item':'Test  medicine 1','value':'0.5 mg'}]
        question = '2026-09-10 09:00 Test  medicine 1'
        fields = {'kind':'lookup','day':'2026-09-10','time':'09:00','item':' Test  medicine 1 '}
        result = resolve_filter_with_boundary_trim(json.dumps(fields),question,records)
        self.assertEqual(result['facts'],['0.5 mg'])
        self.assertEqual(result['record_ids'],['A'])
        fields['item'] = ' Test medicine 1 '
        self.assertEqual(resolve_filter_with_boundary_trim(json.dumps(fields),question,records)['status'],'needs_evidence')

    @unittest.skipUnless(importlib.util.find_spec('opencc'),'optional script conversion dependency')
    def test_script_conversion_preserves_sample_negation_numbers_and_units(self):
        from opencc import OpenCC
        text = '藥尚未服用 0.5 mg；水 2.5 mL'
        actual = OpenCC('t2s').convert(text)
        self.assertIn('尚未服用',actual)
        self.assertTrue(transcript_score(text,actual)['critical_tokens_exact'])

    @unittest.skipUnless(importlib.util.find_spec('lmformatenforcer'),'optional grammar integration dependency')
    def test_grammar_allows_model_eos_when_tokenizer_eos_differs(self):
        from lmformatenforcer import TokenEnforcer, JsonSchemaParser
        from scripts.ai_baseline_backends import grammar_tokenizer_data
        class Tokenizer:
            all_special_ids = [0,1]
            eos_token_id = 1
            def __len__(self): return 6
            def encode(self,text,**kwargs): return [2]
            def decode(self,ids): return ''.join(['EOS0','EOS1','0','{','}',' '][i] for i in ids)
        data = grammar_tokenizer_data(Tokenizer(),0)
        enforcer = TokenEnforcer(data,JsonSchemaParser({'type':'object','properties':{},'additionalProperties':False}))
        self.assertNotIn(0,enforcer.get_allowed_tokens([2]).allowed_tokens)
        enforcer.get_allowed_tokens([2,3])
        allowed = enforcer.get_allowed_tokens([2,3,4]).allowed_tokens
        self.assertIn(0,allowed)
        self.assertNotIn(1,allowed)


if __name__ == '__main__':
    unittest.main()
