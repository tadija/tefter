<script lang="ts">
  import { api } from './api'
  let {user,spaces,reload,signedOut}:{user:string;spaces:{id:string;name:string}[];reload:()=>Promise<void>;signedOut:()=>void}=$props()
  let current=$state(''),password=$state(''),email=$state(''),initial=$state(''),orgName=$state(''),spaceName=$state(''),member=$state(''),org=$state(''),space=$state(''),role=$state('member'),message=$state('')
  let orgs=$state<{id:string;name:string}[]>([])
  async function organizations(){orgs=(await api<{organizations:typeof orgs}>('organizations')).organizations;org=orgs[0]?.id??'';space=spaces[0]?.id??''}
  async function run(work:()=>Promise<void>){message='';try{await work();message='Saved'}catch(e){message=String(e)}}
</script>

<details ontoggle={(e)=>{if(e.currentTarget.open)run(organizations)}}><summary>Account and administration</summary>
<p>Your participant ID <code>{user}</code></p>
<form onsubmit={(e)=>{e.preventDefault();run(async()=>{await api('password','POST',{current,password});signedOut()})}}>
<label>Current password <input type="password" autocomplete="current-password" bind:value={current} required/></label>
<label>New password <input type="password" autocomplete="new-password" minlength="12" bind:value={password} required/></label><button>Change password</button></form>
<details><summary>Manage users and memberships</summary>
<form onsubmit={(e)=>{e.preventDefault();run(async()=>{member=(await api<{id:string}>('users','POST',{email,password:initial})).id;initial=''})}}>
<label>Email <input bind:value={email} type="email" required/></label><label>Initial password <input type="password" bind:value={initial} minlength="12" required/></label><button>Create account</button></form>
<label>Participant ID <input bind:value={member}/></label><button disabled={!member} onclick={()=>run(async()=>{await api('recovery/send','POST',{user:member})})}>Email password setup link</button>
<label>Organization name <input bind:value={orgName}/></label><button onclick={()=>run(async()=>{const created=await api<{id:string}>('organizations','POST',{name:orgName});await organizations();org=created.id})}>Create organization</button>
<label>Organization <select bind:value={org}>{#each orgs as o}<option value={o.id}>{o.name}</option>{/each}</select></label>
{#each ['Grant','Revoke'] as action}<button disabled={!org||!member} onclick={()=>run(async()=>{await api('organizations/'+org+'/members',action==='Grant'?'PUT':'DELETE',{user:member})})}>{action} organization membership</button>{/each}
<label>Space name <input bind:value={spaceName}/></label><button disabled={!org} onclick={()=>run(async()=>{space=(await api<{id:string}>('organizations/'+org+'/spaces','POST',{name:spaceName})).id;await reload()})}>Create organization space</button>
<label>Space <select bind:value={space}>{#each spaces as s}<option value={s.id}>{s.name}</option>{/each}</select></label>
<label>Role <select bind:value={role}><option>member</option><option>admin</option></select></label>
{#each ['Grant','Revoke'] as action}<button disabled={!space||!member} onclick={()=>run(async()=>{await api('spaces/'+space+'/members',action==='Grant'?'PUT':'DELETE',{user:member,role});await reload()})}>{action} space membership</button>{/each}
</details><p role="status">{message}</p></details>

<style>label{display:grid;gap:.25rem;margin:.5rem 0}details{margin:1rem 0}form{max-width:30rem}button,input,select{font:inherit;padding:.3rem .6rem}</style>
