// Literal lookahead cases, budget edges, and inaccessible guest pointers: preparing records must never follow their data addresses or choose replay before an event.
#include "../nvn/nvn_prepare.h"
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr,"FAIL: %s\n",label); } } while (0)
static uint8_t records[65536]; static size_t used;
static size_t emit(uint32_t op, const void *payload, size_t length) {
    size_t at=used, size=(8+length+7)&~(size_t)7; op_hdr h={op,(uint32_t)size};
    if (used+size>sizeof records) abort(); memcpy(records+used,&h,8); if(length)memcpy(records+used+8,payload,length); used+=size; return at;
}
int main(void) {
    void *unreadable=mmap(NULL,(size_t)getpagesize(),PROT_NONE,MAP_PRIVATE|MAP_ANON,-1,0); CHECK(unreadable!=MAP_FAILED,"inaccessible input allocated");
    p_bind_buf ub={.addr=(uintptr_t)unreadable,.size=4096};
    size_t a=emit(OP_BIND_UBO,&ub,sizeof ub), b=emit(OP_DRAW,NULL,0), c=emit(OP_DISPATCH,NULL,0); emit(OP_END,NULL,0);
    nvn_command_plan *p=nvn_command_plan_new(records,used); CHECK(p!=NULL,"records prepare without reading the inaccessible uniform");
    CHECK(nvn_command_plan_lookup(p,records+a,0)==1,"binding before dispatch remains a candidate");
    CHECK(nvn_command_plan_lookup(p,records+b,0)==1,"draw before dispatch remains a candidate");
    CHECK(nvn_command_plan_lookup(p,records+c,0)==1,"a dispatch is found");
    CHECK(nvn_command_plan_lookup(p,records+c+8,0)==0,"END stops the scan");
    CHECK(nvn_command_plan_lookup(p,records+b+1,0)==-1,"an unaligned cursor uses normal replay");
    CHECK(nvn_command_plan_lookup(p,records+used,0)==-1,"an outside cursor uses normal replay");
    CHECK(nvn_command_plan_lookup(p,records+b,1)==-1,"a return stack uses normal replay"); free(p);
    for (int nonzero=0;nonzero<2;nonzero++) {
        used=0; uint32_t bits=(uint32_t)nonzero; a=emit(OP_BARRIER,&bits,4); emit(OP_DRAW,NULL,0); emit(OP_DISPATCH,NULL,0); emit(OP_END,NULL,0);
        p=nvn_command_plan_new(records,used); CHECK(p && nvn_command_plan_lookup(p,records+a,0)==!nonzero,"only a zero barrier passes lookahead"); free(p);
    }
    used=0; a=emit(OP_CALL,&unreadable,sizeof unreadable); emit(OP_END,NULL,0); p=nvn_command_plan_new(records,used);
    CHECK(p && nvn_command_plan_lookup(p,records+a,0)==-1,"a called list is neither read early nor guessed"); free(p);
    used=0; a=emit(OP_MULTI_DRAW,NULL,0); emit(OP_END,NULL,0); p=nvn_command_plan_new(records,used);
    CHECK(p && nvn_command_plan_lookup(p,records+a,0)==-1,"a compact multi-draw uses the original cursor"); free(p);
    for (int passes=4095;passes<=4096;passes++) {
        used=0;for(int i=0;i<passes;i++)emit(OP_DRAW,NULL,0);emit(OP_END,NULL,0);p=nvn_command_plan_new(records,used);
        CHECK(p && nvn_command_plan_lookup(p,records,0)==(passes==4096),"the 4096-op budget matches the ordinary prescan"); free(p);
    }
    op_hdr bad={OP_DRAW,0}; memcpy(records,&bad,8); CHECK(!nvn_command_plan_new(records,8),"zero-size records are rejected");
    CHECK(!nvn_command_plan_new(NULL,8) && !nvn_command_plan_new(records,7),"null and short input are rejected");
    munmap(unreadable,(size_t)getpagesize()); printf("t_command_prepare: %d checks, %d failed\n",checks,failed);return failed!=0;
}
