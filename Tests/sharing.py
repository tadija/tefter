"""Cross-space grants, stable references, fresh previews/search and copy policy."""
from identity import Workspace
import http.client
import io
import zipfile


class Sharing(Workspace):
    def test_grants_revoke_search_export(self):
        a = self.admin
        source = self.call('GET','spaces',session=a)[1]['spaces'][0]['id']
        self.call('POST','users',{'email':'reader@test.org','password':self.password},a)
        b = self.login('reader@test.org')
        target = self.call('GET','spaces',session=b)[1]['spaces'][0]['id']
        src, dst = f'spaces/{source}/', f'spaces/{target}/'
        self.call('POST',src+'write',{'path':'secret.md','text':'classified platypus'},a,204)
        grant = self.call('POST',src+'shares',{'path':'secret.md','target':target,'allowExport':False},a)[1]
        self.call('POST',dst+'references',{'grant':grant['id']},a,404)
        ref = self.call('POST',dst+'references',{'grant':grant['id']},b)[1]
        route = dst+'references/'+ref['id']
        self.assertEqual(self.call('GET',route,session=b)[1]['file']['text'],'classified platypus')
        self.call('GET',src+'file?path=secret.md',session=b,expected=404)
        self.call('DELETE',src+'shares/'+ref['id'],session=b,expected=404)
        hits = self.call('POST',dst+'search',{'query':'platypus','allSpaces':True},b)[1]['hits']
        self.assertEqual(hits[0]['reference'],ref['id'])
        original = self.call('GET',src+'file?path=secret.md',session=a)[1]
        self.call('POST',src+'move',{'path':'secret.md','destination':'renamed.md','revision':original['document']['revision']},a,204)
        self.assertEqual(self.call('GET',route,session=b)[1]['file']['document']['path'],'renamed.md')
        archive = self.export(dst+'export',b)
        with zipfile.ZipFile(io.BytesIO(archive)) as z:
            self.assertIn('.tefter/references/'+ref['id']+'.json',z.namelist())
            self.assertFalse(any('shared-copies' in n for n in z.namelist()))
            self.assertNotIn(b'classified',b''.join(z.read(n) for n in z.namelist()))
        self.export(dst+'export?includeShared=true',b,403)
        allowed = self.call('POST',src+'shares',{'path':'renamed.md','target':target,'allowExport':True},a)[1]
        self.call('POST',dst+'references',{'grant':allowed['id']},b)
        self.call('DELETE',dst+'references/'+ref['id'],session=b,expected=204)
        archive = self.export(dst+'export?includeShared=true',b)
        with zipfile.ZipFile(io.BytesIO(archive)) as z:
            self.assertEqual(z.read('shared-copies/'+allowed['id']+'/content.md'),b'classified platypus')
            self.assertIn('shared-copies/'+allowed['id']+'/ATTRIBUTION.json',z.namelist())
        self.call('DELETE',src+'shares/'+allowed['id'],session=a,expected=204)
        self.call('GET',dst+'references/'+allowed['id'],session=b,expected=404)
        view = self.call('GET',dst+'references',session=b)[1]['references'][0]
        self.assertFalse(view['available'])
        self.assertNotIn('document',view)
        self.assertEqual(self.call('POST',dst+'search',{'query':'platypus','allSpaces':True},b)[1]['hits'],[])
        self.export(dst+'export?includeShared=true',b,404)
        self.export(dst+'export',b)
        self.stop()
        self.start()
        self.call('GET',dst+'references/'+allowed['id'],session=b,expected=404)

    def export(self,path,session,status=200):
        conn = http.client.HTTPConnection('127.0.0.1',self.port,timeout=5)
        try:
            conn.request('GET','/api/v1/'+path,headers=session)
            res=conn.getresponse(); data=res.read()
            self.assertEqual(res.status,status,data[:200])
            return data
        finally: conn.close()
