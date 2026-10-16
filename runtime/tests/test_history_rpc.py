import json
import unittest
from runtime.xcreen_rpc import HistoryPager


class HistoryTests(unittest.TestCase):
    def test_byte_bounds_pixels_snapshots_and_stale_cursor(self):
        history = [{'role':'user','content':[{'type':'text','text':'hello data:image/png;base64,AAAA'}, {'type':'image_url','image_url':{'url':'secret-pixels'}}]}]
        history += [{'role':'assistant','content':'x'*100000}] + [{'role':'assistant','content':str(i)} for i in range(50)]
        pager = HistoryPager()
        first = pager.page('session', history, limit=20, max_bytes=48000)
        encoded = json.dumps(first).encode()
        self.assertLessEqual(len(encoded), 48000)
        self.assertNotIn(b'secret-pixels', encoded)
        self.assertNotIn(b'data:image', encoded)
        self.assertTrue(first['messages'][1]['oversized'])
        cursor = first['next_cursor']
        history.clear()
        second = pager.page('session', [], cursor=cursor)
        self.assertEqual(len(second['messages']), 20)
        with self.assertRaises(ValueError):
            pager.page('other-session', [], cursor=cursor)
        for _ in range(4):
            pager.page('session', [])
        with self.assertRaisesRegex(ValueError,'stale'):
            pager.page('session', [], cursor=cursor)
        with self.assertRaisesRegex(ValueError,'stale'):
            HistoryPager().page('session', [], cursor=cursor)
