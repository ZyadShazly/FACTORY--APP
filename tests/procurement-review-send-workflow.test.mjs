import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration=fs.readFileSync('supabase/migrations/202607260002_procurement_review_send_workflow.sql','utf8');

test('purchase requests and orders have user-facing names',()=>{
  assert.match(migration,/purchase_requests\s+add column if not exists display_name text/i);
  assert.match(migration,/purchase_orders\s+add column if not exists display_name text/i);
  assert.match(migration,/set_purchase_request_display_name/i);
});

test('quote conversion creates a draft purchase order for review',()=>{
  assert.match(migration,/create_purchase_order_draft_from_quote/i);
  assert.match(migration,/q\.currency,'draft'/i);
  assert.doesNotMatch(migration,/q\.currency,'approved'/i);
  assert.match(migration,/Purchase order already exists for this quote/i);
});

test('approval and sending are separate audited actions',()=>{
  assert.match(migration,/create or replace function public\.approve_purchase_order/i);
  assert.match(migration,/status='approved'/i);
  assert.match(migration,/purchase_order_approved/i);
  assert.match(migration,/create or replace function public\.mark_purchase_order_sent/i);
  assert.match(migration,/status='sent'/i);
  assert.match(migration,/purchase_order_sent/i);
});

test('send metadata is retained for audit trail',()=>{
  assert.match(migration,/sent_by uuid references public\.profiles/i);
  assert.match(migration,/sent_at timestamptz/i);
  assert.match(migration,/supplier_send_reference text/i);
});

test('new RPCs remain protected',()=>{
  for(const signature of [
    'set_purchase_request_display_name\\(uuid,text\\)',
    'create_purchase_order_draft_from_quote\\(uuid,text\\)',
    'approve_purchase_order\\(uuid\\)',
    'mark_purchase_order_sent\\(uuid,text\\)'
  ]){
    assert.match(migration,new RegExp(`revoke all on function public\\.${signature} from public,anon`,'i'));
  }
  assert.match(migration,/security definer set search_path=public,private,pg_temp/ig);
});
