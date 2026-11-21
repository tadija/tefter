<script lang="ts">
 import {onMount} from 'svelte'
 import {api} from './api'
 let {base,path,user}:{base:string;path:string;user:string}=$props()
 type Comment={id:string;author:string;parent?:string;body:string;deleted:boolean;created:string}
 type Thread={revision:string;comments:Comment[]}
 let thread=$state<Thread>(),body=$state(''),parent=$state<string>(),edit=$state<string>(),error=$state('')
 onMount(async()=>{try{thread=await api(base+'comments?path='+encodeURIComponent(path))}catch(e){error=String(e)}})
 async function submit(remove=false){
   try{
     thread=await api(base+'comments','POST',{path,revision:thread?.revision,body:remove?undefined:body,parent,id:edit})
     parent=undefined;edit=undefined;body='';error=''
   }catch(e){error=String(e)}
 }
</script>
<h3>Comments</h3>
{#if error}<p role="alert">{error}</p>{/if}
{#if thread}
{#each thread.comments as c}
<div style:margin-left={c.parent?'1.5rem':'0'}><small>{c.author} · {c.created}</small><p>{c.deleted?'Deleted comment':c.body}</p>
{#if !c.deleted}{#if !c.parent}<button onclick={()=>{parent=c.id;edit=undefined;body=''}}>Reply</button>{/if}
{#if c.author===user}<button onclick={()=>{edit=c.id;parent=undefined;body=c.body}}>Edit</button>
<button onclick={()=>{if(confirm('Delete this comment?')){edit=c.id;submit(true)}}}>Delete</button>{/if}{/if}</div>
{:else}<p>No comments yet.</p>{/each}
<label>{edit?'Edit comment':parent?'Reply':'New comment'} <textarea bind:value={body}></textarea></label>
<button disabled={!body.trim()} onclick={()=>submit()}>Save comment</button>
{#if edit||parent}<button onclick={()=>{edit=undefined;parent=undefined;body=''}}>Cancel</button>{/if}
{/if}
