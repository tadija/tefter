<script lang="ts">
  import { onMount } from 'svelte'
  import { marked } from 'marked'
  import DOMPurify from 'dompurify'
  import Comments from './Comments.svelte'
  import { api } from './api'
  let {space}: {space:string} = $props()
  type Doc = {path:string; revision:string; id?:string; type:string; title:string; status?:string; sprint?:string; release?:string; url?:string}
  type Tree = {directories:string[]; documents:Doc[]}
  let tree = $state<Tree>({directories:[],documents:[]})
  let path = $state(''), body = $state(''), revision = $state<string>(), selected = $state<Doc>()
  let dest = $state(''), folder = $state(''), error = $state(''), loading = $state(true)
  let kind = $state('doc'), title = $state(''), url = $state(''), status = $state('todo'), sprint = $state(''), release = $state(''), assignee = $state('')
  let mode = $state('Files'), read = $state(false), filter = $state('')
  let people = $state<{id:string;name:string}[]>([])
  let user=$state(''),query=$state(''),allSpaces=$state(false),searched=$state(false)
  let hits=$state<{space:string;path:string;title:string}[]>([])
  const base = () => 'spaces/'+space+'/'
  async function run(work:()=>Promise<void>) { error=''; try { await work() } catch(e) { error=String(e) } }
  async function refresh() { tree = await api<Tree>(base()+'tree') }
  onMount(async()=>{ await run(async()=>{ await refresh(); user=(await api<{user:string}>('session')).user; people=(await api<{people:typeof people}>(base()+'people')).people }); loading=false })
  function clear() { path=''; body=''; selected=undefined; revision=undefined; title=''; url=''; assignee=''; sprint=''; release=''; read=false; kind='doc' }
  async function open(doc:Doc) {
    await run(async()=>{ const file=await api<{document:Doc;text:string}>(base()+'file?path='+encodeURIComponent(doc.path)); selected=file.document; path=doc.path; revision=file.document.revision; body=file.text; read=true })
  }
  async function save() {
    await run(async()=>{
      let text=body
      if (!selected && kind!=='doc') {
        const fields:Record<string,string>={id:crypto.randomUUID(),type:kind,title}
        if(kind==='url') Object.assign(fields,{url,created:new Date().toISOString()})
        if(kind==='task') { fields.status=status; if(sprint) fields.sprint=sprint; if(assignee) fields.assignee=assignee }
        if(['task','sprint'].includes(kind)&&release) fields.release=release
        text='---\n'+Object.entries(fields).map(([k,v])=>k+': '+JSON.stringify(v)).join('\n')+'\n---\n'+body
      }
      await api(base()+'write','POST',{path,text,revision}); await refresh()
      const doc=tree.documents.find(d=>d.path===path); if(doc) await open(doc)
    })
  }
  function preview(text:string) {
    return DOMPurify.sanitize(marked.parse(text,{async:false}),{ALLOWED_TAGS:['p','h1','h2','h3','h4','h5','h6','ul','ol','li','em','strong','del','blockquote','pre','code','a','br','hr','table','thead','tbody','td','th'],ALLOWED_ATTR:['href','title'],ALLOWED_URI_REGEXP:/^(?:https?:\/\/|mailto:|#)/i})
  }
  let docs=$derived(tree.documents.filter(d=>(d.title+' '+d.path).toLowerCase().includes(filter.toLowerCase())))
  function progress(doc:Doc) { const tasks=tree.documents.filter(d=>d.type==='task'&&(d.sprint===doc.id||d.release===doc.id)); return tasks.filter(d=>d.status==='done').length+'/'+tasks.length+' done' }
</script>

{#if error}<p role="alert">{error}</p>{/if}
{#if loading}<p role="status">Loading workspace…</p>{:else}
<nav aria-label="Views">{#each ['Files','Kanban','Tasks','Backlog','Sprints','Releases','URLs','People','Search'] as tab}<button aria-pressed={mode===tab} onclick={()=>mode=tab}>{tab}</button>{/each}</nav>
<div class="workspace">
<aside>
{#if mode==='Search'}
<form onsubmit={(e)=>{e.preventDefault();run(async()=>{hits=(await api<{hits:typeof hits}>(base()+'search','POST',{query,allSpaces})).hits;searched=true})}}>
<label>Search content and comments <input bind:value={query} required/></label><label><input type="checkbox" bind:checked={allSpaces}/> All accessible spaces</label><button>Search</button></form>
{#each hits as hit}<p>{hit.title} · {hit.path} · {hit.space}</p>{:else}{#if searched}<p>No matches.</p>{/if}{/each}
{:else if mode==='People'}<h2>People</h2>{#each people as p}<p>{p.name}</p>{/each}
{:else}
<label>Filter <input bind:value={filter}/></label>
{#if mode==='Files'}
<ul>{#each [...tree.directories.map(p=>({path:p,dir:true})),...docs.map(d=>({path:d.path,dir:false}))].sort((a,b)=>a.path.localeCompare(b.path)) as item}
<li style:padding-left={(item.path.split('/').length-1)*0.8+'rem'}>{#if item.dir}{item.path.split('/').pop()}/{:else}<button onclick={()=>open(tree.documents.find(d=>d.path===item.path)!)}>{item.path.split('/').pop()}</button>{/if}</li>
{:else}<li>This space is empty.</li>{/each}</ul>
<label>Directory path <input bind:value={folder}/></label><button onclick={()=>run(async()=>{await api(base()+'directory','POST',{path:folder});folder='';await refresh()})}>Create directory</button>
{:else if mode==='Kanban'}
{#each ['todo','in-progress','done'] as column}<h3>{column}</h3>{#each docs.filter(d=>d.type==='task'&&d.status===column) as d}<button onclick={()=>open(d)}>{d.title}</button>{/each}{/each}
{:else}
{#each docs.filter(d=> mode==='Tasks'||mode==='Backlog' ? d.type==='task'&&(mode!=='Backlog'||!d.sprint) : d.type===({Sprints:'sprint',Releases:'release',URLs:'url'} as Record<string,string>)[mode]) as d}
<p><button onclick={()=>open(d)}>{d.title}</button> {['sprint','release'].includes(d.type)?progress(d):d.url??d.status??''}</p>
{:else}<p>No matching items.</p>{/each}
{/if}{/if}
</aside>
<section>
<button onclick={clear}>New file</button>
<a href={'/api/v1/'+base()+'export'} download>Export space</a>
<button onclick={()=>run(async()=>{await api(base()+'rescan','POST');await refresh()})}>Rescan</button>
{#if selected}<h2>{selected.title}</h2><button onclick={()=>read=!read}>{read?'Edit Markdown':'Preview'}</button>{/if}
{#if selected&&read}<article>{@html preview(body.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/,''))}</article>
{:else}
<label>File path <input bind:value={path} disabled={!!selected} placeholder="notes/plan.md"/></label>
{#if !selected}
<label>Type <select bind:value={kind}>{#each ['doc','task','sprint','release','url'] as k}<option>{k}</option>{/each}</select></label>
{#if kind!=='doc'}<label>Title <input bind:value={title}/></label>{/if}
{#if kind==='url'}<label>URL <input type="url" bind:value={url}/></label>{/if}
{#if kind==='task'}<label>Status <select bind:value={status}>{#each ['todo','in-progress','done'] as s}<option>{s}</option>{/each}</select></label>
<label>Assignee <select bind:value={assignee}><option value="">Unassigned</option>{#each people as p}<option value={p.id}>{p.name}</option>{/each}</select></label>
<label>Sprint <select bind:value={sprint}><option value="">Unscheduled</option>{#each tree.documents.filter(d=>d.type==='sprint') as d}<option value={d.id}>{d.title}</option>{/each}</select></label>{/if}
{#if ['task','sprint'].includes(kind)}<label>Release <select bind:value={release}><option value="">None</option>{#each tree.documents.filter(d=>d.type==='release') as d}<option value={d.id}>{d.title}</option>{/each}</select></label>{/if}
{/if}
<label>Markdown <textarea rows="15" bind:value={body}></textarea></label><button onclick={save}>Save</button>
{/if}
{#if selected}<details><summary>Move or delete file</summary><label>Destination <input bind:value={dest}/></label>
<button onclick={()=>run(async()=>{await api(base()+'move','POST',{path,revision,destination:dest});clear();await refresh()})}>Move</button>
<button onclick={()=>run(async()=>{if(confirm('Delete '+path+'?')){await api(base()+'delete','POST',{path,revision});clear();await refresh()}})}>Delete</button></details>{/if}
{#if selected}{#key selected.path}<Comments base={base()} path={selected.path} {user}/>{/key}{/if}
</section></div>{/if}

<style>
 nav{display:flex;gap:.4rem;flex-wrap:wrap;margin:1rem 0}button,input,textarea,select{font:inherit;padding:.35rem .55rem}button{cursor:pointer}button[aria-pressed=true]{background:#214e42;color:white}
 .workspace{display:grid;grid-template-columns:minmax(12rem,1fr) minmax(0,3fr);gap:2rem}section,aside{min-width:0}label{display:grid;margin:.6rem 0}ul{padding:0;list-style:none}article{overflow-wrap:anywhere}textarea{font-family:monospace}details{margin-top:1rem}@media(max-width:700px){.workspace{grid-template-columns:1fr}}
</style>
