import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from scripts.ai_validation_common import aggregate_media, media_score, speech_intervals
from scripts.prepare_ai_validation import chat_cases
from scripts.ai_baseline_filtering import resolve_filter_with_boundary_trim
from scripts.run_ai_validation_pages import match_rows
from scripts.report_ai_validation import raw


class FollowupValidationTests(unittest.TestCase):
    def test_report_rejects_cached_metric_tampering(self):
        from scripts.ai_validation_common import write_jsonl
        with TemporaryDirectory() as temporary:
            root=Path(temporary)
            row=dict(id='one',reference='0.5 mg',text='5 mg',**media_score('0.5 mg','5 mg'))
            row['strict_numeric_unit_match']=True
            write_jsonl(root/'runs/sample/default.jsonl',[row])
            with patch('scripts.report_ai_validation.DATA',root):
                with self.assertRaisesRegex(ValueError,'metric mismatch'):
                    raw('sample','default',[dict(id='one',reference='0.5 mg')])

    def test_document_matching_is_one_to_one(self):
        expected=[[0,0,100,30],[0,40,100,70]]
        self.assertEqual(match_rows(expected,[[0,0,100,30],[1,1,99,29],[0,200,100,230]]),{0:0})

    def test_reference_denominator_and_silence(self):
        self.assertEqual(media_score('12.5 mg','2.5 mg')['score']['reference_characters'],6)
        self.assertFalse(media_score('0.5 mg','5 mg')['strict_numeric_unit_match'])
        row=dict(reference='',text='hello',language='en',**media_score('','hello'))
        self.assertEqual(aggregate_media([row])['all']['control_nonempty'],1)
        self.assertIsNone(aggregate_media([row])['all']['cer'])

    def test_critical_denominator_excludes_noncritical(self):
        rows=[dict(reference=ref,text=text,**media_score(ref,text))
              for ref,text in [('water','water'),('0.05 mL','0.5 mL'),('none','5 mg')]]
        score=aggregate_media(rows)['all']
        self.assertEqual((score['critical_count'],score['critical_match'],score['spurious_critical']),(1,0,1))

    def test_vad_contiguous_minimum_and_invalid(self):
        self.assertFalse(speech_intervals([0.9]*7))
        self.assertEqual(speech_intervals([0.1]+[0.9]*8),[[512,4608]])
        self.assertFalse(speech_intervals([0.9]*4+[0.1]+[0.9]*4))
        with self.assertRaises(ValueError): speech_intervals([float('nan')])

    def test_fixture_contract_gold_is_consistent(self):
        rows=chat_cases()
        self.assertEqual(len(rows),120)
        self.assertEqual(len({r['question'] for r in rows}),120)
        for row in rows:
            if 'target' in row:
                self.assertEqual(resolve_filter_with_boundary_trim(json.dumps(row['target']),row['question'],row['records']),row['expected'])

    def test_patient_scope_must_be_enforced_by_caller(self):
        row=next(r for r in chat_cases() if r['family']=='paraphrase')
        raw=json.dumps(row['target'])
        records=row['records']+[dict(row['records'][1],id='foreign-id',patient_id='foreign-B',value='FOREIGN SENTINEL')]
        result=resolve_filter_with_boundary_trim(raw,row['question'],records)
        # Characterizes the present research helper, not an app data leak.
        self.assertIn('foreign-id',result['record_ids'])
        scoped=[r for r in records if r['patient_id']=='selected-fixture-A']
        self.assertEqual(resolve_filter_with_boundary_trim(raw,row['question'],scoped),row['expected'])

    def test_unsupported_scope_not_counted_as_contract_accuracy(self):
        rows=chat_cases()
        extension=[r for r in rows if r['scope']=='extension_boundary']
        self.assertEqual(len(extension),20)
        self.assertTrue(all('target' not in r and r['expected']['status']=='needs_evidence' for r in extension))


if __name__=='__main__': unittest.main()
