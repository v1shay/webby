// Runs only in a ChatGPT tab explicitly opened by the widget.
if (location.hostname !== 'chatgpt.com') return false;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const deadline = Date.now() + 90000;
let editor;
while (Date.now() < deadline) {
  editor = document.querySelector('#prompt-textarea, #mobile-composer-prompt') || document.querySelector('textarea[name=prompt]');
  if (editor && editor.getBoundingClientRect().height > 0) break;
  await sleep(350);
}
if (!editor || (editor.innerText || editor.value || '').trim()) return false;
const images = draft.images || [];
if (images.length) {
  let input = [...document.querySelectorAll('input[type=file]')].find(x => !x.accept || /image|png|jpeg|\*/i.test(x.accept));
  if (!input) return false;
  const transfer = new DataTransfer();
  for (const image of images) {
    const bytes = Uint8Array.from(atob(image.data), c => c.charCodeAt(0));
    transfer.items.add(new File([bytes], image.name, {type:'image/png'}));
  }
  input.files = transfer.files;
  input.dispatchEvent(new Event('change', {bubbles:true}));
  await sleep(1000);
}
editor.focus();
if (editor instanceof HTMLTextAreaElement) {
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(editor,draft.text);
} else {
  // ProseMirror handles the real editing operation and updates its state.
  document.execCommand('insertText',false,draft.text);
}
editor.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:draft.text}));
const readyAfter=Date.now()+(images.length ? 4000:350);
while (Date.now()<deadline) {
  const send=document.querySelector('[data-testid="send-button"],button[aria-label="Send prompt"],button[aria-label="Send message"],button[aria-label="Send"]');
  const uploading=document.querySelector('[role="progressbar"], [data-testid*="upload"] [aria-busy="true"]');
  const previews=document.querySelectorAll('button[aria-label*="Remove"], [data-testid*="attachment"], [data-testid*="file-thumbnail"]');
  if (Date.now()>readyAfter && send && !send.disabled && send.getAttribute('aria-disabled')!=='true' && !uploading && (!images.length || previews.length>=images.length)) {
    const current=editor instanceof HTMLTextAreaElement ? editor.value:editor.innerText;
    if (current.trim() !== draft.text.trim()) return false;
    send.click();return true;
  }
  await sleep(350);
}
return false;
