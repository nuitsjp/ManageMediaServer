#include "gateway_model.h"
#include <assert.h>
#include <stdio.h>
using namespace gateway;
int main() {
  assert(!strcmp(reception_status(false, 20000, 19000), "未確認"));
  assert(!strcmp(reception_status(true, 19000, 20000), "未確認"));
  assert(!strcmp(reception_status(true, 20799, 10000), "3時間以内に受信"));
  assert(!strcmp(reception_status(true, 20800, 10000), "3時間以上受信なし"));
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
    const uint8_t voltage[]={0x1e}, battery[]={0xc8}, unknown[]={0xff};
    assert(decode(1,0x20,0x20,voltage,1,kind,value) && kind==VOLTAGE && value==30);
    n->metrics[kind]={value,3000+i,true,true};
    assert(divisor(n->identity,kind)==10);
    assert(decode(1,0x21,0x20,battery,1,kind,value) && kind==BATTERY && value==200);
    n->metrics[kind]={value,4000+i,true,true};
    assert(divisor(n->identity,kind)==2);
    assert(!decode(1,0x20,0x20,unknown,1,kind,value));
    assert(!decode(1,0x21,0x20,unknown,1,kind,value));
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

  Metric empty, b={200,1000,true,false}, v={30,1000,true,false};
  PowerRefresh power;
  assert(power.due(0,empty,empty,false)); // Bootstrap reads even a restored sleepy child once.
  power.scheduled(0,true);
  assert(!power.due(POWER_RETRY_MS-1,empty,empty,true));
  assert(!power.due(POWER_RETRY_MS,empty,empty,false));
  assert(power.due(POWER_RETRY_MS,empty,empty,true));
  power.scheduled(POWER_RETRY_MS,true);
  power.scheduled(POWER_RETRY_MS*2,true);
  assert(!power.needs_configuration()); // No endless report-configuration writes.
  assert(power.due(POWER_RETRY_MS*3,empty,empty,true)); // Read fallback still works.
  power.configured=true;
  power.last_attempt_ms=1000;
  assert(!power.due(1000+POWER_REFRESH_MS-1,b,v,true));
  assert(power.due(1000+POWER_REFRESH_MS,b,v,false));
  power.requested=true;
  assert(!power.due(1000+POWER_RETRY_MS-1,b,v,true));
  assert(power.due(1000+POWER_RETRY_MS,b,v,false)); // HA restart can request new battery readings.
  power.scheduled(1000+POWER_RETRY_MS,false);
  assert(!power.due(1000+POWER_RETRY_MS+1,b,v,true));
  power.configured=false;power.unsupported=true;power.config_attempts=0;
  assert(!power.needs_configuration());
  power.last_attempt_ms=0xfffffff0U;power.requested=true;
  assert(!power.due(20,b,v,true));
  assert(power.due(POWER_RETRY_MS,b,v,true)); // millis() wrap must not break the retry guard.
  PowerBudget budget;
  for (unsigned i=0;i<10;++i) {
    uint32_t now=i*POWER_BATCH_GAP_MS;
    assert(budget.ready(now));budget.sent(now);
    assert(!budget.ready(now+POWER_BATCH_GAP_MS-1));
  }
  assert(POWER_REPORT_MIN_S==3600 && POWER_REPORT_MAX_S==21600);
}
