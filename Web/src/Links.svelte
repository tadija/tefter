<script lang="ts">
  type Link = {
    path: string;
    title: string;
    url?: string;
    description?: string;
    previewTitle?: string;
    image?: string;
    favicon?: string;
    created?: string;
    published?: string;
    tags?: string[];
  };
  let {
    docs,
    base,
    open,
  }: { docs: Link[]; base: string; open: (path: string) => void } = $props();
  let layout = $state("Grid"),
    sort = $state("Newest");
  let items = $derived(
    [...docs].sort((a, b) =>
      sort === "Title"
        ? a.title.localeCompare(b.title)
        : (b.created ?? "").localeCompare(a.created ?? ""),
    ),
  );
  function image(path: string, kind: string) {
    return (
      "/api/v1/" +
      base +
      "preview-image?kind=" +
      kind +
      "&path=" +
      encodeURIComponent(path)
    );
  }
</script>

<label>
  Layout <select bind:value={layout}>
    <option>Grid</option><option>List</option>
  </select>
</label>
<label>
  Sort links <select bind:value={sort}>
    <option>Newest</option><option>Title</option>
  </select>
</label>
<div class:grid={layout === "Grid"}>
  {#each items as item}<article>
      {#if item.image && layout === "Grid"}<img
          loading="lazy"
          src={image(item.path, "image")}
          alt=""
        />{/if}
      <button onclick={() => open(item.path)}>
        {#if item.favicon}<img
            class="icon"
            src={image(item.path, "favicon")}
            alt=""
          />{/if}{item.title}
      </button>
      {#if item.previewTitle && item.previewTitle !== item.title}<p>
          {item.previewTitle}
        </p>{/if}
      {#if item.url}<a
          href={item.url}
          target="_blank"
          rel="noopener noreferrer"
        >
          {item.url}
        </a>{/if}
      <p>{item.description ?? ""}</p>
      <small>{item.tags?.join(", ") ?? ""} {item.created ?? ""}</small>
      {#if item.published}<small>Published {item.published}</small>{/if}
    </article>{:else}<p>No matching URLs.</p>{/each}
</div>

<style>
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 10rem), 1fr));
    gap: 0.5rem;
  }
  article {
    border: 1px solid #c6cfc8;
    padding: 0.65rem;
    overflow-wrap: anywhere;
  }
  img {
    max-width: 100%;
    max-height: 8rem;
  }
  .icon {
    width: 1em;
    margin-right: 0.4em;
  }
  a,
  small {
    display: block;
  }
  label {
    display: block;
    margin: 0.5rem 0;
  }
</style>
