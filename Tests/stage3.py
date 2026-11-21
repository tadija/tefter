"""Stage 3 integration tests only; shared fixture does not run prior-stage tests."""
import unittest
from identity import Workspace


class Repos(Workspace):
    def test_repo_ownership_and_explicit_grants(self):
        a = self.admin
        self.call('POST', 'users', {'email':'other@example.test','password':self.password}, a)
        b = self.login('other@example.test')
        sa = self.call('GET','spaces',session=a)[1]['spaces'][0]['id']
        sb = self.call('GET','spaces',session=b)[1]['spaces'][0]['id']
        registration = {'name':'Tefter','location':'https://example.org/tefter.git'}
        central = self.call('POST','repos',registration,a)[1]['id']
        own = self.call('POST','repos',dict(registration,space=sb),b)[1]['id']
        self.call('POST','repos',registration,b,403)
        self.call('POST','repos',dict(registration,space=sa),b,404)
        self.call('GET','repos',session=b,expected=403)
        self.assertEqual([r['id'] for r in self.call('GET','repos?space='+sb,session=b)[1]['repos']],[own])
        self.call('GET',f'spaces/{sb}/repos/{central}',session=b,expected=404)
        self.call('PUT',f'repos/{central}/grants',{'space':sb},b,403)
        self.call('PUT',f'repos/{central}/grants',{'space':sb},a,204)
        self.call('GET',f'spaces/{sb}/repos/{central}',session=b)
        self.call('GET',f'spaces/{sa}/repos/{own}',session=a,expected=404)
        self.call('PUT',f'repos/{own}/grants',{'space':sa},a,403)
        self.call('DELETE',f'repos/{central}/grants',{'space':sb},a,204)
        self.call('GET',f'spaces/{sb}/repos/{central}',session=b,expected=404)
        for location in ['https://secret@example.org/r','https://u:secret@example.org/r','https://example.org/r?token=secret','-x','relative/path','ext::sh attack']:
            self.call('POST','repos',dict(registration,location=location),a,400)
        self.stop()
        self.start()
        self.call('GET',f'spaces/{sb}/repos/{own}',session=b)
        self.assertEqual(self.call('GET','repos',session=a)[1]['repos'][0]['id'],central)

if __name__ == '__main__':
    unittest.main()
