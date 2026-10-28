import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS'};
Deno.serve(async (req:Request)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 if(req.method!=='POST')return Response.json({error:'Use POST for game actions.'},{status:405,headers:cors});
 const auth=req.headers.get('Authorization'); if(!auth?.startsWith('Bearer '))return Response.json({error:'Join as a guest to continue.'},{status:401,headers:cors});
 const url=Deno.env.get('SUPABASE_URL')!, service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
 const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
 const userClient=createClient(url,Deno.env.get('SUPABASE_ANON_KEY')!,{global:{headers:{Authorization:auth}}});
 const {data:{user},error:authError}=await userClient.auth.getUser();
 if(authError||!user)return Response.json({error:'Your guest session expired. Refresh to reconnect.'},{status:401,headers:cors});
 try{
  const body=await req.json();
  const action=String(body.action??''); const code=body.code==null?null:String(body.code).toUpperCase();
  if(code!==null&&!/^[A-Z2-9]{6}$/.test(code))return Response.json({error:'Room codes are six letters or numbers.'},{status:400,headers:cors});
  const {data,error}=await admin.rpc('game_action',{p_action:action,p_uid:user.id,p_code:code,p_nickname:typeof body.nickname==='string'?body.nickname:null,p_clue:typeof body.clue==='string'?body.clue:null,p_target:typeof body.target_id==='string'?body.target_id:null,p_guess:typeof body.guess==='string'?body.guess:null});
  if(error)return Response.json({error:error.message.replace(/^.*?ERROR:\s*/,'')},{status:400,headers:cors});
  return Response.json(data,{headers:{...cors,'Cache-Control':'no-store'}});
 }catch{return Response.json({error:'That request could not be read. Please try again.'},{status:400,headers:cors});}
});
