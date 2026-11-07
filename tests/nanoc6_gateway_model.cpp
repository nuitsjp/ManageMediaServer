#include "gateway_model.h"
#include <assert.h>
#include <stdio.h>
using namespace gateway;
int main() {
  Fleet fleet;
  for (unsigned i=0; i<10; ++i) {
    char ieee[17]; snprintf(ieee,sizeof(ieee),"a4c138%010x",i+1);
    Node *n=fleet.find(ieee); assert(n);
    strcpy(n->identity.manufacturer,"Zbeacon"); strcpy(n->identity.model,"TH01");
    assert(known(n->identity));
    Kind kind; int32_t value;
    const uint8_t temperature[]={0xa0,0x0a}, humidity[]={0x0f,0x11};
    assert(decode(0x402,0,0x29,temperature,2,kind,value) && kind==TEMPERATURE && value==2720);
    n->metrics[kind]={value,1000+i,true,true};
    assert(decode(0x405,0,0x21,humidity,2,kind,value) && kind==HUMIDITY && value==4367);
    n->metrics[kind]={value,2000+i,true,true};
    assert(divisor(n->identity,kind)==100);
  }
  assert(fleet.nodes[0].metrics[TEMPERATURE].received_ms==1000);
  assert(fleet.nodes[9].metrics[TEMPERATURE].received_ms==1009);
  assert(fresh(121000,fleet.nodes[0].metrics[TEMPERATURE]));
  assert(!fresh(121001,fleet.nodes[0].metrics[TEMPERATURE]));
  Metric wrap={10,0xfffffff0U,true,true}; assert(fresh(10,wrap));
  Kind kind; int32_t value;
  const uint8_t negative[]={0xda,0xfd}, invalid[]={0,0x80}, missing[]={0xff,0xff};
  assert(decode(0x402,0,0x29,negative,2,kind,value) && value==-550);
  assert(!decode(0x402,0,0x29,invalid,2,kind,value));
  assert(!decode(0x405,0,0x21,missing,2,kind,value));
  assert(!decode(0x402,0,0x21,negative,2,kind,value));
  assert(!decode(0x402,0,0x29,negative,1,kind,value));
  Identity other={}; strcpy(other.model,"TH01"); strcpy(other.manufacturer,"unknown"); assert(!known(other));
  strcpy(other.model,"TS0201"); strcpy(other.manufacturer,"_TZ3000_itnrsufe");
  assert(known(other) && divisor(other,HUMIDITY)==10);
  assert(!fleet.find("0000000000000000") && !fleet.find("invalid"));
  for (unsigned i=10;i<32;++i) {char ieee[17];snprintf(ieee,sizeof(ieee),"a4c138%010x",i+1);assert(fleet.find(ieee));}
  assert(!fleet.find("a4c1380000000099") && fleet.overflow==1);
}
