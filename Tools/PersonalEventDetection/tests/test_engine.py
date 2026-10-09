import tempfile
import unittest
import uuid
import numpy as np
from personal_events.data import windows,label_windows,chronological_split,snapshot_id
from personal_events.policy import EpisodeState,Policy,evaluate
from personal_events.models import candidates,Detector
from personal_events.training import pack,unpack,train


class EngineTests(unittest.TestCase):
    def test_registry_and_model_roundtrip(self):
        self.assertEqual(len(candidates()),450)
        self.assertEqual(len({s['id'] for s in candidates()}),450)
        rng=np.random.default_rng(4); raw=rng.normal(size=(100,2,2,16)).astype('float32')
        y=np.tile([0,1],50); raw[y==1,:,1,:]+=5
        for head in ['ridge','random_forest','extra_trees','stacking','rbf_svm','prevalence']:
            model=Detector(dict(groups=['cardiac'],head=head)).fit(raw,y)
            np.testing.assert_allclose(model.predict(raw),unpack(pack(model)).predict(raw))
            missing=raw.copy(); missing[:,:,1,:]=np.nan
            self.assertTrue(np.isnan(model.predict(missing)).all())

    def test_episode_restart_retry_swap_and_gap(self):
        state=EpisodeState(); policy=Policy()
        args=dict(owner='a',type_id='t',device='d',model='m1',policy=policy)
        for t in (1000,1008,1016): result=state.step(t,.95,**args)
        self.assertIsNotNone(result)
        from dataclasses import asdict
        restored=EpisodeState(**asdict(state)); args['model']='m2'
        self.assertIsNone(restored.step(1016,.95,**args))
        self.assertEqual(restored.step(1024,.95,**args)['id'],result['id'])
        self.assertIsNone(restored.step(1100,float('nan'),**args))
        for t in (1300,1308,1316): next_result=restored.step(t,.95,**args)
        self.assertNotEqual(next_result['id'],result['id'])
        args['owner']='b'; other=EpisodeState()
        for t in (1000,1008,1016): other_result=other.step(t,.95,**args)
        self.assertNotEqual(other_result['id'],result['id'])

    def test_causal_windows_unknown_and_conflicting_reviews(self):
        times,raw=windows([(t,t) for t in range(32,101)],[],start=64,end=96)
        self.assertEqual(raw[0,:,1,:].max(),times[0]-1)
        self.assertTrue(np.isnan(raw[:,:,0,:]).all())
        positives=[dict(id='p',start=0,end=96)]
        np.testing.assert_array_equal(label_windows(times,positives,[(0,80)]),[-1,-1,1,1])
        self.assertTrue((label_windows(times,[],[])==-1).all())

    def test_splits_keep_days_and_boundary_episodes_apart(self):
        times=np.arange(0,10*86400,60,dtype=float); labels=np.arange(len(times))%2
        parts=chronological_split(times,labels,[dict(id='cross',start=6*86400-300,end=6*86400+300)])
        self.assertLess(times[parts[0]].max()+32,times[parts[1]].min())
        self.assertLess(times[parts[1]].max()+32,times[parts[2]].min())
        self.assertFalse(any(6*86400-332<=times[i]<=6*86400+332 for p in parts for i in p))

    def test_time_saved_penalizes_duplicate_alerts_and_unknown_is_not_negative(self):
        policy=Policy(smoothing=1,persistence=1,cooldown=0,min_events=1,min_negative_hours=0)
        times=np.arange(1000,1800,8,dtype=float); scores=np.zeros(len(times)); scores[2:5]=.9; scores[8:10]=.9
        events=[dict(id='one',start=1000,end=1200)]
        result=evaluate(times,scores,events,[(1200,1800)],policy)
        self.assertEqual(result['coveredEvents'],1)
        self.assertGreater(result['falseAlertsPerDay'],0)
        unknown=evaluate(times,scores,[],[],policy)
        self.assertEqual(unknown['falseAlertsPerDay'],0)
        self.assertFalse(unknown['eligible'])

    def test_training_selection_and_no_reuse_of_protected_test(self):
        times=[]; positive=[]; negative=[]
        for day in range(10):
            lo=1_700_000_000//86400*86400+day*86400
            times.extend(range(lo,lo+7200,8)); negative.append((lo,lo+3600))
            for j in range(3): positive.append(dict(id=f'{day}-{j}',start=lo+4000+j*800,end=lo+4300+j*800))
        times=np.array(times,dtype=float); labels=label_windows(times,positive,negative)
        rng=np.random.default_rng(42); raw=rng.normal(60,1,size=(len(times),2,2,16)).astype('float32')
        raw[labels==1,:,1,:]+=80
        specs=[dict(id='cardiac__ridge',groups=['cardiac'],head='ridge')]
        with tempfile.TemporaryDirectory() as cache:
            model,report=train(times,raw,labels,positive,negative,snapshot='test',cache=cache,specs=specs)
            self.assertEqual(len(report['candidates']),1)
            self.assertTrue(report['promotion'],report)
            self.assertIsNotNone(model)
            with self.assertRaisesRegex(ValueError,'independent'):
                train(times,raw,labels,positive,negative,snapshot='test',cache=cache,specs=specs,previous_test_end=times.max())
            with self.assertRaisesRegex(ValueError,'training labels were reviewed'):
                train(times,raw,labels,positive,negative,snapshot='test',cache=cache,specs=specs,
                    availability=np.full(len(times),times.max()+1))


if __name__=='__main__': unittest.main()
