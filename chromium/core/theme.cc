#include "core/theme.h"
#include "core/model.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <sstream>

namespace birch::core { namespace {
double Clamp(double x,double a=0,double b=1){return std::max(a,std::min(b,x));}
double Decode(double x){return x<=.04045?x/12.92:std::pow((x+.055)/1.055,2.4);}
double Encode(double x){x=Clamp(x);return x<=.0031308?12.92*x:1.055*std::pow(x,1/2.4)-.055;}
Lab Mix(Lab x,Lab y,double t){return {x.L+(y.L-x.L)*t,x.a+(y.a-x.a)*t,x.b+(y.b-x.b)*t};}
Lab Base(bool dark){return dark?ToOKLab({.12,.12,.14}):Lab{1,0,0};}
}
std::optional<RGB> ParseHex(const std::string& input){std::string s=input;auto b=s.find_first_not_of(" \t\r\n"),e=s.find_last_not_of(" \t\r\n");if(b==std::string::npos)return {};s=s.substr(b,e-b+1);if(!s.empty()&&s[0]=='#')s.erase(0,1);if(s.size()!=6)return {};unsigned v=0;std::istringstream in(s);in>>std::hex>>v;if(in.fail()||!in.eof())return {};return RGB{((v>>16)&255)/255.,((v>>8)&255)/255.,(v&255)/255.};}
std::string Hex(RGB c){return (std::string("#") + [&]{char b[7];std::snprintf(b,sizeof(b),"%02X%02X%02X",int(std::lround(Clamp(c.r)*255)),int(std::lround(Clamp(c.g)*255)),int(std::lround(Clamp(c.b)*255)));return std::string(b);}());}
Lab ToOKLab(RGB c){double r=Decode(c.r),g=Decode(c.g),b=Decode(c.b);double l=std::cbrt(.4122214708*r+.5363325363*g+.0514459929*b),m=std::cbrt(.2119034982*r+.6806995451*g+.1073969566*b),s=std::cbrt(.0883024619*r+.2817188376*g+.6299787005*b);return {.2104542553*l+.7936177850*m-.0040720468*s,1.9779984951*l-2.4285922050*m+.4505937099*s,.0259040371*l+.7827717662*m-.8086757660*s};}
RGB FromOKLab(Lab v){v.L=Clamp(v.L);auto calc=[](Lab q){double l=std::pow(q.L+.3963377774*q.a+.2158037573*q.b,3),m=std::pow(q.L-.1055613458*q.a-.0638541728*q.b,3),s=std::pow(q.L-.0894841775*q.a-1.2914855480*q.b,3);return RGB{4.0767416621*l-3.3077115913*m+.2309699292*s,-1.2684380046*l+2.6097574011*m-.3413193965*s,-.0041960863*l-.7034186147*m+1.7076147010*s};};RGB c=calc(v);for(int i=0;i<24&&(c.r<-.0005||c.g<-.0005||c.b<-.0005||c.r>1.0005||c.g>1.0005||c.b>1.0005);++i){v.a*=.92;v.b*=.92;c=calc(v);}return {Encode(c.r),Encode(c.g),Encode(c.b)};}
Lab Soften(RGB color,double intensity,bool dark,double brightness){Lab lab=ToOKLab(color),orig=lab;double c=std::hypot(lab.a,lab.b);if(c>.0001){double soft=.15*std::tanh(c/.15)*.9;lab.a*=soft/c;lab.b*=soft/c;}if(dark)lab.L=std::min(lab.L,.3+.2*lab.L);lab=Mix(lab,orig,Clamp(brightness));return Mix(Base(dark),lab,Clamp(intensity));}
double GrainAmount(const Theme&t){return Clamp(t.grain.value_or(.35));} double BrightnessAmount(const Theme&t){return Clamp(t.brightness.value_or(0));}
GrainTile GenerateGrainTile(){GrainTile tile;tile.rgba.resize(256*256*4);uint64_t seed=0x5EED50FFE1ULL;auto rand=[&](){seed=seed*6364136223846793005ULL+1442695040888963407ULL;return double(seed>>11)/double(1ULL<<53);};for(size_t i=0;i<256*256;++i){double n=(rand()+rand()+rand()+rand())/4-.5,v=Clamp(n*3.2,-1,1);auto alpha=static_cast<unsigned char>(std::abs(v)*255);auto shade=static_cast<unsigned char>(v>0?alpha:0);tile.rgba[i*4]=shade;tile.rgba[i*4+1]=shade;tile.rgba[i*4+2]=shade;tile.rgba[i*4+3]=alpha;}return tile;}
std::vector<Lab> SoftLabs(const Theme&t,bool dark){std::vector<Lab> out;for(auto&s:t.colors)if(auto c=ParseHex(s))out.push_back(Soften(*c,t.intensity,dark,BrightnessAmount(t)));if(out.empty())out.push_back(Base(dark));return out;}
std::array<RGB,16> GradientStops(const Theme&t,bool dark){auto labs=SoftLabs(t,dark);if(labs.size()==1){Lab a=labs[0],b=a;a.L=std::min(1.,a.L+.025);b.L=std::max(0.,b.L-.025);labs={a,b};}std::array<RGB,16> out;for(int k=0;k<16;++k){double u=double(k)/15*(labs.size()-1);size_t i=std::min(size_t(u),labs.size()-2);double f=u-i,e=.5*f+.5*f*f*(3-2*f);out[k]=FromOKLab(Mix(labs[i],labs[i+1],e));}return out;}
}
