import json
import unittest

from scripts.ai_training_common import check_splits, completion_tokens
from scripts.prepare_ai_training_chat import make_cases
from scripts.run_ai_training_chat import accept_teacher,prompt_ids
from scripts.ai_training_asr_features import decoder_supervision
from scripts.run_ai_training_ocr import decode_ctc
from scripts.report_ai_training import verified_transcript_score
from scripts.ai_baseline_metrics import transcript_score


class TrainingBoundariesTest(unittest.TestCase):
    def test_split_contamination_rejected(self):
        a=make_cases('train',10)
        b=make_cases('validation',10)
        check_splits({'train':a,'validation':b})
        b[0]['question']=a[0]['question']
        with self.assertRaises(ValueError):
            check_splits({'train':a,'validation':b})

    def test_prompt_loss_is_masked_and_eos_learned(self):
        ids,labels=completion_tokens([1,2,3],[4,5],9,6)
        self.assertEqual(ids,[1,2,3,4,5,9])
        self.assertEqual(labels,[-100,-100,-100,4,5,9])
        with self.assertRaises(ValueError):
            completion_tokens([1,2,3],[4,5],9,5)

    def test_prompt_extracts_token_ids_from_processor_mapping(self):
        class Row:
            def tolist(self):return [11,22,33]
        class Processor:
            def apply_chat_template(self,*args,**kwargs):
                self.kwargs=kwargs
                return {'input_ids':[Row()],'attention_mask':[[1,1,1]]}
        class Backend:processor=Processor()
        self.assertEqual(prompt_ids(Backend(),'question'),[11,22,33])
        self.assertTrue(Backend.processor.kwargs['return_dict'])

    def test_medical_target_contains_no_advice(self):
        for row in make_cases('train',20):
            if row['family'] in [8,9]:
                self.assertEqual(row['target'],{'kind':'medical','day':None,'time':None,'item':None})
                self.assertEqual(row['expected']['facts'],[])

    def test_values_negation_and_missing_parameters(self):
        for row in make_cases('test',20):
            if row['family'] in [6,7]:
                self.assertEqual(row['expected']['status'],'needs_evidence')
            elif row['family']==4:
                self.assertEqual(row['expected']['status'],'no_records')
            elif row['family']<6:
                self.assertEqual(row['expected']['facts'],[row['records'][1]['value']])

    def test_teacher_output_requires_exact_fields(self):
        row=make_cases('train',1)[0]
        self.assertTrue(accept_teacher(row,json.dumps(row['target'])))
        wrong=dict(row['target'],item='wrong medicine')
        self.assertFalse(accept_teacher(row,json.dumps(wrong)))
        self.assertFalse(accept_teacher(row,'```json\n'+json.dumps(row['target'])+'\n```'))
        self.assertFalse(accept_teacher(row,json.dumps(dict(row['target'],advice='take more'))))

    def test_asr_prefix_is_input_but_not_loss_and_silence_learns_eos(self):
        self.assertEqual(decoder_supervision([1,2,3,4,90,91,99]),
                         ([1,2,3,4,90,91],[-100,-100,-100,90,91,99]))
        self.assertEqual(decoder_supervision([1,2,3,4,99]),([1,2,3,4],[-100,-100,-100,99]))

    def test_ctc_preserves_repeats_separated_by_blank(self):
        characters=['blank','0','.','5',' ','m','L']
        self.assertEqual(decode_ctc([1,1,0,1,2,1,3,4,5,6],characters),'00.05 mL')

    def test_legacy_scores_are_verified_then_corrected_to_reference_denominator(self):
        old=transcript_score(reference='a',prediction='abcd')
        result=verified_transcript_score(reference='abcd',prediction='a',recorded=old,legacy=True)
        self.assertEqual(result['character_edits'],3)
        self.assertEqual(result['reference_characters'],4)
        with self.assertRaises(ValueError):
            verified_transcript_score(reference='abcd',prediction='a',recorded=old)
        with self.assertRaises(ValueError):
            verified_transcript_score(reference='abcd',prediction='a',recorded=dict(old,character_edits=0),legacy=True)

    def test_silence_scoring_uses_empty_reference(self):
        result=verified_transcript_score(reference='',prediction='hello',
            recorded=transcript_score(reference='hello',prediction=''),legacy=True)
        self.assertEqual(result['reference_characters'],0)
        self.assertTrue(result['silence_hallucination'])


if __name__=='__main__':
    unittest.main()
