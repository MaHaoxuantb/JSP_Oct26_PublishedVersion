// JSP-Oct26-GPU-Quick; ©2026 ThomasB. Exactly one dispatched threadgroup.
#include <metal_stdlib>
using namespace metal;
// SHARED_HEADER
kernel void shapes(device const uint* masks [[buffer(0)]],device uint* out [[buffer(1)]],constant uint2& info [[buffer(2)]],uint lane [[thread_index_in_threadgroup]]){
 for(uint b=lane;b<info.x;b+=256)out[b]=shape(masks+4*b,int(info.y));
}
kernel void paths(device const int* sizes [[buffer(0)]],device const uint* seeds [[buffer(1)]],device int* out [[buffer(2)]],constant uint2& info [[buffer(3)]],uint lane [[thread_index_in_threadgroup]]){
 const int n=int(info.y*info.y),cols=int(info.y),sid=int(lane/32),l=int(lane%32);
 threadgroup int aa[8*121],bb[8*121];
 for(int board=sid;board<int(info.x);board+=8){threadgroup int* prev=aa+sid*121;threadgroup int* next=bb+sid*121;
  for(int c=l;c<n;c+=32)prev[c]=has(seeds+4*board,c)?0:1000000000;
  simdgroup_barrier(mem_flags::mem_threadgroup);
  for(int step=1;step<n;step++){bool changed=false;
   for(int c=l;c<n;c+=32){int best=prev[c],v[4]={c-cols,c+cols,c-1,c+1};bool ok[4]={c>=cols,c+cols<n,c%cols>0,c%cols+1<cols};
    for(int k=0;k<4;k++)if(ok[k])best=min(best,prev[v[k]]+min(sizes[board*n+c],sizes[board*n+v[k]]));next[c]=best;changed|=best!=prev[c];}
   simdgroup_barrier(mem_flags::mem_threadgroup);threadgroup int* tmp=prev;prev=next;next=tmp;if(!simd_any(changed))break;
  }
  for(int c=l;c<n;c+=32)out[board*n+c]=prev[c];simdgroup_barrier(mem_flags::mem_threadgroup);
 }
}
