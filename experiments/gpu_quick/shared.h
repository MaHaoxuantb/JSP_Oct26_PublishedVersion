// JSP-Oct26-GPU-Quick; ©2026 ThomasB. Same shape algorithm for CPU and Metal.
#ifdef __METAL_VERSION__
#define GLOBAL device
#else
#include <cstdint>
using uint = uint32_t;
#define GLOBAL
#endif
inline bool has(GLOBAL const uint* m,int c){return (m[c/32] & (uint(1)<<(c%32)))!=0;}
inline uint shape(GLOBAL const uint* m,int side){
 int n=side*side,loR=side,hiR=-1,loC=side,hiC=-1,start=-1,total=0;
 for(int c=0;c<n;c++)if(has(m,c)){int r=c/side,k=c%side;loR=r<loR?r:loR;hiR=r>hiR?r:hiR;loC=k<loC?k:loC;hiC=k>hiC?k:hiC;start=c;total++;}
 if(!total)return 0;
 uint seen[4]={0,0,0,0};int q[121],head=0,tail=1;q[0]=start;seen[start/32]|=uint(1)<<(start%32);
 while(head<tail){int c=q[head++],v[4]={c-side,c+side,c-1,c+1};bool ok[4]={c>=side,c+side<n,c%side>0,c%side+1<side};
  for(int k=0;k<4;k++)if(ok[k]&&has(m,v[k])&&!(seen[v[k]/32]&(uint(1)<<(v[k]%32)))){seen[v[k]/32]|=uint(1)<<(v[k]%32);q[tail++]=v[k];}}
 bool connected=tail==total;uint syms=0;int cap=-2;
 for(int t=1;t<=7;t++){bool invariant=true;int fixed=0,fc=-1;
  for(int c=0;c<n;c++)if(has(m,c)){int r=2*(c/side)-loR-hiR,k=2*(c%side)-loC-hiC,a,b;
   switch(t){case 1:a=k;b=-r;break;case 2:a=-r;b=-k;break;case 3:a=-k;b=r;break;case 4:a=r;b=-k;break;case 5:a=-r;b=k;break;case 6:a=k;b=r;break;default:a=-k;b=-r;}
   if(a==r&&b==k){fixed++;fc=c;}a+=loR+hiR;b+=loC+hiC;
   if(a<0||b<0||a%2||b%2||a/2>=side||b/2>=side||!has(m,(a/2)*side+b/2)){invariant=false;break;}}
  if(invariant){syms|=uint(1)<<(t-1);if(fixed!=1)cap=-1;else if(cap==-2)cap=fc;else if(cap!=fc)cap=-1;}}
 if(!connected||!syms||cap<0)cap=-1;
 return uint(connected)|(uint(syms!=0)<<1)|(syms<<2)|(uint(cap+1)<<9);
}
