// JSP-Oct26-GPU-Quick; ©2026 ThomasB.
#include "shared.h"
#include <queue>
#include <vector>
#include <functional>
extern "C" void cpuShapes(const uint* masks,uint* out,int count,int n){for(int i=0;i<count;i++)out[i]=shape(masks+4*i,n);}
extern "C" void cpuPaths(const int* sizes,const uint* seeds,int* out,int count,int side){
 int n=side*side;for(int b=0;b<count;b++){int* d=out+b*n;bool seen[121]={};int seedCount=0;for(int c=0;c<n;c++){bool isSeed=has(seeds+4*b,c);seedCount+=isSeed;d[c]=isSeed?0:1000000000;}if(seedCount==0||seedCount==n)continue;
 for(int step=0;step<n;step++){int x=-1,v=1000000000;for(int c=0;c<n;c++)if(!seen[c]&&d[c]<v){x=c;v=d[c];}if(x<0)break;seen[x]=true;
 int ns[4]={x-side,x+side,x-1,x+1};bool ok[4]={x>=side,x+side<n,x%side>0,x%side+1<side};for(int k=0;k<4;k++)if(ok[k]){int y=ns[k],w=sizes[b*n+x]<sizes[b*n+y]?sizes[b*n+x]:sizes[b*n+y];if(v+w<d[y])d[y]=v+w;}}}}
extern "C" bool certifyPaths(const int* sizes,const uint* seeds,const int* d,int count,int side){
 int n=side*side;for(int b=0;b<count;b++)for(int c=0;c<n;c++){
 int x=d[b*n+c];bool seed=has(seeds+4*b,c);if(x<0||(x!=1000000000&&x>(n-1)*n)||(seed&&x!=0)||(!seed&&x==0))return false;
 int ns[4]={c-side,c+side,c-1,c+1};bool ok[4]={c>=side,c+side<n,c%side>0,c%side+1<side};bool tight=false;
 for(int k=0;k<4;k++)if(ok[k]){int v=ns[k],a=sizes[b*n+c],bb=sizes[b*n+v],w=a<bb?a:bb,y=d[b*n+v];if(x>y+w)return false;if(x==y+w)tight=true;}
 if(!seed&&x!=1000000000&&!tight)return false;}return true;}

extern "C" void cpuHeapPaths(const int* sizes,const uint* seeds,int* out,int count,int side){
 int n=side*side;using Item=std::pair<int,int>;for(int b=0;b<count;b++){
 int* d=out+b*n;int seedCount=0;for(int c=0;c<n;c++){bool isSeed=has(seeds+4*b,c);seedCount+=isSeed;d[c]=isSeed?0:1000000000;}if(seedCount==0||seedCount==n)continue;
 std::vector<Item> storage;storage.reserve(5*n);std::priority_queue<Item,std::vector<Item>,std::greater<Item>> q(std::greater<Item>(),std::move(storage));
 for(int c=0;c<n;c++)if(d[c]==0)q.push({0,c});
 while(!q.empty()){auto [v,x]=q.top();q.pop();if(d[x]!=v)continue;int ns[4]={x-side,x+side,x-1,x+1};bool ok[4]={x>=side,x+side<n,x%side>0,x%side+1<side};
 for(int k=0;k<4;k++)if(ok[k]){int y=ns[k],a=sizes[b*n+x],bb=sizes[b*n+y],value=v+(a<bb?a:bb);if(value<d[y]){d[y]=value;q.push({value,y});}}}}}
