/***********************************************************************************************************************************/
/***********************************************************************************************************************************/
/**                                                                                                                               **/
/**  Kamstrup 382 decoder                                                                                                         **/
/**                                                                                                                               **/
/***********************************************************************************************************************************/
/***********************************************************************************************************************************/
/*
 * TODO:
 * 
 * 
 * **********************************************************************************************************************************
 * DONE:
 *  
 * support register range
 * repeat last command when timeing out
 * set repeat factor
 * debug levels
 * 
 * handle ascii 
 * handle yy:mm:dd 
 * handle hh:mm:ss
 * default values t 1600 / d 2
 * repeat command
 * 
 * cancel command
 * wait timeout also on success but 3 times on failure with no result
 */


#include <SoftwareSerial.h>

#include <Cmd.h> 

/***********************************************************************************************************************************/
/***********************************************************************************************************************************/
/**                                                                                                                               **/
/**  Configurations                                                                                                               **/
/**                                                                                                                               **/
/***********************************************************************************************************************************/
/***********************************************************************************************************************************/

// Pin definitions
#define PIN_KAMSER_RX  9  // Kamstrup IR interface RX
#define PIN_KAMSER_TX  10  // Kamstrup IR interface TX
#define PIN_LED        13  // Standard Arduino LED

// Kamstrup optical IR serial
// #define KAMTIMEOUT 300  // Kamstrup timeout after transmit
// #define KAMTIMEOUT 1000  // Kamstrup timeout after transmit

SoftwareSerial kamSer(PIN_KAMSER_RX, PIN_KAMSER_TX, false);  // Initialize serial

#define KAMBAUD 9600

#include "generichelper.h"



const char xl100_bytestext[] PROGMEM = " Bytes "; 



/***********************************************************************************************************************************/
/***********************************************************************************************************************************/
/**                                                                                                                               **/
/**  Kamstrup protocol - defs                                                                                                     **/
/**     Kamstrup setup - 382Jx3                                                                                                   **/
/**                                                                                                                               **/
/***********************************************************************************************************************************/
/***********************************************************************************************************************************/

#define KAM_GetRegister 0x10

/*
word const kregnums[] = { 0x0001,0x03ff,0x0027,0x041e,0x041f,0x0420 };
char* kregstrings[]   = { "Energy in","Current Power","Max Power","Voltage p1","Voltage p2","Voltage p3" };
#define NUMREGS 6     // Number of registers above
*/

/*
 * https://ing.dk/blog/kamstrup-meter-protocol-127052
 * 
 * Byte 5 fra måleren er enhed jf. følgende:
    units = {0: '', 1: 'Wh', 2: 'kWh', 3: 'MWh', 4: 'GWh', 
    5: 'j', 6: 'kj', 7: 'Mj', 8: 'Gj', 9: 'Cal', 
    10: 'kCal', 11: 'Mcal', 12: 'Gcal', 13: 'varh', 14: 'kvarh', 
    15: 'Mvarh', 16: 'Gvarh', 17: 'VAh', 18: 'kVAh', 19: 'MVAh', 
    20: 'GVAh', 21: 'kW', 22: 'kW', 23: 'MW', 24: 'GW', 
    25: 'kvar', 26: 'kvar', 27: 'Mvar', 28: 'Gvar', 29: 'VA', 
    30: 'kVA', 31: 'MVA', 32: 'GVA', 33: 'V', 34: 'A', 
    35: 'kV',36: 'kA', 37: 'C', 38: 'K', 39: 'l', 
    40: 'm3', 41: 'l/h', 42: 'm3/h', 43: 'm3xC', 44: 'ton', 
    45: 'ton/h', 46: 'h', 47: 'hh:mm:ss', 48: 'yy:mm:dd', 49: 'yyyy:mm:dd', 
    50: 'mm:dd', 51: '', 52: 'bar', 53: 'RTC', 54: 'ASCII', 
    55: 'm3 x 10', 56: 'ton x 10', 57: 'GJ x 10', 58: 'minutes', 59: 'Bitfield', 
    60: 's', 61: 'ms', 62: 'days', 63: 'RTC-Q', 64: 'Datetime'}
    
 */

// Units
#define MAX_UNITS 64
char *KAM_units[MAX_UNITS+1] {
   0, "Wh","kWh","MWh","GWh",           // 0-4
   "j", "kj", "Mj","Gj","Cal",                    // 5-9
   "kCal", "MCal","Gcal","varh", "kvarh",                    // 10-14
   "Mvarh", "Gvarh", "VAh", "kVAh", "MVAh",                       // 15-19
   "GVAh","kW","kW","MW","GW",                     // 20-24
   "kvar", "kvar", "Mvar", "Gvar", "VA",                        // 25-29
   "kVA", "MVA", "GVA", "V", "A",                        // 30-34
   "kV","kA","C","K","l",                     // 35-39
   "m3", "l/h", "m3/h", "m3xC","ton",   // 40-44
   "ton/h", "h", "clock", "yy:mm:dd","yyyy:mm:dd",    // 45-49
   "date3", "number", "bar", "RTC","ASCII",       // 50-54
   "m3x10", "tonx10", "GJx10", "minutes","Bitfield",       // 55-59
   "s", "ms", "days", "RTC-Q", "Datetime",       // 60-64
};




/***********************************************************************************************************************************/
/***********************************************************************************************************************************/
/**                                                                                                                               **/
/**  Globals                                                                                                                      **/
/**                                                                                                                               **/
/***********************************************************************************************************************************/
/***********************************************************************************************************************************/


#define MAX_TXMSG_SIZE 50

#define MAX_RXMSG_SIZE 100

byte rxdata[MAX_RXMSG_SIZE];  // buffer to hold received data
int rxnext;
int rxmsgstart;

byte rxAppMsgBuffer[MAX_RXMSG_SIZE];  // buffer to hold app layer msg
byte *rxAppMsg = rxAppMsgBuffer+1;
int rxmsglen;

byte sentLastMsgBuf[MAX_TXMSG_SIZE];  // buffer to hold the last app msg for repeat
int sentLastMsgLen;
int sentRepeatFactor = 4;
int sentRepeatCount = 0;

unsigned long resultTime;
bool expectResult;
bool hasMessage;

unsigned long blinkTime;
bool blinkOn;

word currentRegList[] = { 0, 0 };

char globalbuf[20];

unsigned long receiveTimeout = 1600;

#define DEBUGLEVEL_COMMAND 0
#define DEBUGLEVEL_START 1
#define DEBUGLEVEL_REPEAT 3
#define DEBUGLEVEL_RECRAW 6
#define DEBUGLEVEL_SNDRAW 10
#define MAX_DEBUGLEVEL 10


int debugLevel = DEBUGLEVEL_START;


char const stdhexformat[] = "%2.2X ";


/***********************************************************************************************************************************/
/***********************************************************************************************************************************/
/**                                                                                                                               **/
/**  Org stuff                                                                                                                    **/
/**                                                                                                                               **/
/***********************************************************************************************************************************/
/***********************************************************************************************************************************/
/*
// kamReadReg - read a Kamstrup register
float kamReadReg(unsigned short kreg) {

  byte recvmsg[40];  // buffer of bytes to hold the received data
  float rval;        // this will hold the final value

  // prepare message to send and send it
  byte sendmsg[] = { 0x3f, KAM_GetRegister, 0x01, (kregnums[kreg] >> 8), (kregnums[kreg] & 0xff) };
  kamSend(sendmsg, 5, kregnums[kreg]);

  // listen if we get an answer
  unsigned short rxnum = kamReceive(recvmsg);

  // check if number of received bytes > 0 
  if(rxnum != 0){
    
    // decode the received message
    rval = kamDecode(kreg,recvmsg);
    
    // print out received value to terminal (debug)
    Serial.print(kregstrings[kreg]);
    Serial.print(F(": "));
    Serial.print(rval);
    Serial.print(" ");
    Serial.println();
    
    return rval;
  }
}

// kamSend - send data to Kamstrup meter
void kamSend(byte const *msg, int msgsize, int kreg) {

  // append checksum bytes to message
  byte newmsg[msgsize+2];
  char text[10];
  
  for (int i = 0; i < msgsize; i++) { newmsg[i] = msg[i]; }
  newmsg[msgsize++] = 0x00;
  newmsg[msgsize++] = 0x00;
  int c = crc_1021(newmsg, msgsize);
  newmsg[msgsize-2] = (c >> 8);
  newmsg[msgsize-1] = c & 0xff;

  // build final transmit message - escape various bytes
  byte txmsg[20] = { 0x80 };   // prefix
  int txsize = 1;
  for (int i = 0; i < msgsize; i++) {
    if (newmsg[i] == 0x06 or newmsg[i] == 0x0d or newmsg[i] == 0x1b or newmsg[i] == 0x40 or newmsg[i] == 0x80) {
      txmsg[txsize++] = 0x1b;
      txmsg[txsize++] = newmsg[i] ^ 0xff;
    } else {
      txmsg[txsize++] = newmsg[i];
    }
  }
  txmsg[txsize++] = 0x0d;  // EOF

  sprintf( text, "%4.4X ", kreg );
  Serial.print(">>Start sending: ");
  Serial.println(text);
  
  for (int x = 0; x < txsize; x++) {
    sprintf( text,stdhexformat, txmsg[x] );
    if ( x % 4 )
      Serial.print(text );
    else
      Serial.println(text );
  }
  Serial.println("\r\n>>Send done");
  delay(200);
    
  // send to serial interface
  for (int x = 0; x < txsize; x++) {
    kamSer.write(txmsg[x]);
  }

}

// kamReceive - receive bytes from Kamstrup meter
unsigned short kamReceive(byte recvmsg[]) {

  byte rxdata[50];  // buffer to hold received data
  char text[10];
  unsigned long rxindex = 0;
  unsigned long starttime = millis();
  
  Serial.println(">>Start receiving");

  kamSer.flush();  // flush serial buffer - might contain noise

  byte r;
  
  // loop until EOL received or timeout
  while(r != 0x0d){
    
    // handle rx timeout
    if(millis()-starttime > receiveTimeout) {
      Serial.println("\r\n\r\n>>Timed out listening for data");
      return 0;
    }

    // handle incoming data
    if (kamSer.available()) {

      // receive byte
      r = kamSer.read();
      if(r != 0x40) {  // don't append if we see the start marker
        // append data
        rxdata[rxindex] = r;
        rxindex++; 

        sprintf( text, stdhexformat, r );
        if ( rxindex % 4 )
          Serial.print(text );
        else
          Serial.println(text );
      }

    }
  }


  Serial.println("\r\n>>Data done");
  
  // remove escape markers from received data
  unsigned short j = 0;
  for (unsigned short i = 0; i < rxindex -1; i++) {
    if (rxdata[i] == 0x1b) {
      byte v = rxdata[i+1] ^ 0xff;
      if (v != 0x06 and v != 0x0d and v != 0x1b and v != 0x40 and v != 0x80){
        Serial.print("Missing escape ");
        Serial.println(v,HEX);
      }
      recvmsg[j] = v;
      i++; // skip
    } else {
      recvmsg[j] = rxdata[i];
    }
    j++;
  }
  
  // check CRC
  if (crc_1021(recvmsg,j)) {
    Serial.println("CRC error: ");
    return 0;
  }
  
  return j;
  
}

// kamDecode - decodes received data
float kamDecode(unsigned short const kreg, byte const *msg) {

  // skip if message is not valid
  if (msg[0] != 0x3f or msg[1] != 0x10) {
    return false;
  }
  if (msg[2] != (kregnums[kreg] >> 8) or msg[3] != (kregnums[kreg] & 0xff)) {
    return false;
  }
    
  // decode the mantissa
  long x = 0;
  for (int i = 0; i < msg[5]; i++) {
    x <<= 8;
    x |= msg[i + 7];
  }
  
  // decode the exponent
  int i = msg[6] & 0x3f;
  if (msg[6] & 0x40) {
    i = -i;
  };
  float ifl = pow(10,i);
  if (msg[6] & 0x80) {
    ifl = -ifl;
  }

  // return final value
  return (float )(x * ifl);

}
*/

/***********************************************************************************************************************************/
/***********************************************************************************************************************************/
/**                                                                                                                               **/
/**  Setup / Loop                                                                                                                 **/
/**                                                                                                                               **/
/***********************************************************************************************************************************/
/***********************************************************************************************************************************/

/***********************************************************************************************************************************/
void setup() {

  delay(500);
  Serial.begin(57600);
  
  pinMode(PIN_LED, OUTPUT);
  digitalWrite(PIN_LED, 0);
  
  commandSetup(); 
  delay(100); 
    
  // setup kamstrup serial
  pinMode(PIN_KAMSER_RX,INPUT);
  pinMode(PIN_KAMSER_TX,OUTPUT);
  kamSer.begin(KAMBAUD);

  rxnext = 0;
  rxmsgstart = -1;

  blinkTime = millis();
  blinkOn = true;

/*
  while ( true ) {
    cReadReg( 0, 0 );
    delay(1000);    
  }
/*   */  
  
}


/***********************************************************************************************************************************/
void loop() {

  // blink every second
  if ( millis() > blinkTime ) {
      blinkTime = millis()+1000;
      digitalWrite(PIN_LED, (blinkOn?HIGH:LOW));
      blinkOn = ! blinkOn;
  }

  handleRX();

  if ( hasMessage ) {
    // write raw message out
    if ( debugLevel >= DEBUGLEVEL_RECRAW ) { 
      Serial.print(F("\r\n>> Received Raw "));
      printMessage( rxAppMsg, rxmsglen );
    } else if ( debugLevel >= DEBUGLEVEL_REPEAT ) { 
      Serial.println();
    }
    
    // decode different message types
    if (  rxmsglen < 1 ) {
      // do nothing for empty msg
    } else if ( rxAppMsg[0] == KAM_GetRegister ) {
      decodeGetRegister(rxAppMsg, rxmsglen);
    } else {
      if ( debugLevel < DEBUGLEVEL_RECRAW ) { 
        Serial.print(F(" -- Result "));
        printMessageShort( rxAppMsg, rxmsglen );
        Serial.println();
      }
    }
    
    // reset
    hasMessage = false;
    expectResult = false;

    delay( receiveTimeout );
    sentRepeatCount = 0;
    getNextRegList();
  }

  // handle commands if not waiting for result
  if ( expectResult ) {
    // timeout means repeat or next reg
    if ( millis() > resultTime ) {
      expectResult = false;

      if ( sentRepeatCount < sentRepeatFactor ) {
        if ( debugLevel >= DEBUGLEVEL_REPEAT ) { 
          Serial.println( F( ">> Repeat last send " ) );
        } else if ( debugLevel >= DEBUGLEVEL_COMMAND ) { 
          Serial.print(".");
        }
        repeatSend();
        if ( expectResult ){
          resultTime = millis()+receiveTimeout;
        }
      } else {
        sentRepeatCount = 0;
        if ( debugLevel >= DEBUGLEVEL_REPEAT ) { 
          Serial.println(F(">>  -- no result"));
        } else if ( debugLevel >= DEBUGLEVEL_COMMAND ) { 
          Serial.println(F(" -- no result"));
        }
        delay( receiveTimeout*3 );
        getNextRegList();
      }
    }
        
  } 
  

  bool oldExpectResult;
  if ( cmdPoll() ) {
    if ( ! oldExpectResult ) {
      sentRepeatCount = 0;
      // check for expect message to start timer
      if ( expectResult ){
        resultTime = millis()+receiveTimeout;
      }
    }    
  }

}





/***********************************************************************************************************************************/
/***********************************************************************************************************************************/
/**                                                                                                                               **/
/**  Handle receive of data                                                                                                       **/
/**                                                                                                                               **/
/***********************************************************************************************************************************/
/***********************************************************************************************************************************/

int countRXBytes() {
  int count;

  // calc count for msg
  if ( rxmsgstart == -1 ) {
    return -1;
  }

  if ( rxmsgstart > rxnext ) {
    count = rxnext - rxmsgstart + MAX_RXMSG_SIZE;
  } else {
    count = rxnext - rxmsgstart;
  }
  return count;
}


void handleRX() {

  // handle incoming data
  while (kamSer.available()) {
    // receive byte
    byte r = kamSer.read();

    // start marker
    if(r == 0x40) { 
      // message start
      if ( rxmsgstart != -1 ) {
        // msg started but not finished --> ignore it
        Serial.print(F("\r\n >>Err: Message started but not finished - " ));
        Serial.print( countRXBytes() );
        SerialPrintlnPROG( xl100_bytestext );
      }
      rxmsgstart = rxnext;

    } else if (r == 0x0d) {
      // message done -> decode escapes and check crc --> copy to rxAppMsg

      int i = rxmsgstart;
      rxmsglen = 0;
      byte isEscape = false;
      
      while ( i != rxnext ) {
        byte v = rxdata[i];
        if ( i == rxmsgstart ) {
          // check start value of 3f 
          if (v != 0x3f){
            Serial.print(F("\r\n >>Err: Wrong destination address -  "));
            Serial.println(v,HEX);
          }
          rxAppMsgBuffer[rxmsglen++] = v;
        } else if ( isEscape ) {
          v = v ^ 0xff;
          if (v != 0x06 and v != 0x0d and v != 0x1b and v != 0x40 and v != 0x80){
            Serial.print(F("\r\n >>Err: Wrong escaped value -  "));
            Serial.println(v,HEX);
          }
          rxAppMsgBuffer[rxmsglen++] = v;
          isEscape = false;
        } else if (rxdata[i] == 0x1b) {
          isEscape = true;
        } else {
          if (v == 0x06 or v == 0x0d or v == 0x1b or v == 0x40 or v == 0x80){
            Serial.print(F("\r\n >>Err: Non-escaped value - "));
            Serial.println(v,HEX);
          }
          rxAppMsgBuffer[rxmsglen++] = v;
        }
        i++;
        if ( i == MAX_RXMSG_SIZE ) {
          i = 0;
        }
        // should check if msg value is too long ???
      }
      if ( isEscape ) {
        Serial.print(F("\r\n >>Err: Missing value for escape at end of message  "));
      }
  
      // check CRC
      if (crc_1021(rxAppMsgBuffer,rxmsglen)) {
        Serial.println(F("\r\n >>Err: Wrong crc value -  "));
      }

      // remove crc AND 3f from msglen
      rxmsglen -= min(3,rxmsglen); 

      hasMessage = true;
      rxmsgstart = -1;
  
    } else if ( rxmsgstart != -1 ) {
      // next bytes in message
      rxdata[rxnext++] = r;
      if ( rxnext == MAX_RXMSG_SIZE ) {
        rxnext = 0;
      }
      if ( rxnext == rxmsgstart ) {
        Serial.println(F("\r\n >>Err: message too long (overflow) "));
      }

    } else {
      // unsolicited message
      Serial.print(F("\r\n >>Err: Received data outside message - " ));
      sprintf( globalbuf, stdhexformat, r );
      Serial.println( globalbuf );
    }

  }
  
}

/***********************************************************************************************************************************/
/***********************************************************************************************************************************/
/**                                                                                                                               **/
/**  Generic send and receive routines                                                                                            **/
/**                                                                                                                               **/
/***********************************************************************************************************************************/
/***********************************************************************************************************************************/

// crc_1021 - calculate crc16
long crc_1021(byte const *inmsg, unsigned int len){
  long creg = 0x0000;
  for(unsigned int i = 0; i < len; i++) {
    int mask = 0x80;
    while(mask > 0) {
      creg <<= 1;
      if (inmsg[i] & mask){
        creg |= 1;
      }
      mask>>=1;
      if (creg & 0x10000) {
        creg &= 0xffff;
        creg ^= 0x1021;
      }
    }
  }
  return creg;
}


// takes an application layer message adds address, crc and translates the byte stuffing before sending it with 80h/0dh start+stop
long sendRequest( byte const *appmsg, unsigned int len ) {
  byte dataMsg[len+3];
  byte physicalMsg[(len*2)+3];
  
  dataMsg[0] = 0x3f;
  physicalMsg[0] = 0x80;
  
  // copy message together with destination address for CRC calc
  memcpy( dataMsg+1, appmsg, len );

  // copy sent msg for repeat
  memcpy( sentLastMsgBuf, appmsg, len );
  sentLastMsgLen = len;
  
  // calc crc (includes crc 0 in calc - is that necessary?
  dataMsg[len+1] = 0x00;
  dataMsg[len+2] = 0x00;
  int c = crc_1021(dataMsg, len+3);
  dataMsg[len+1] = (c >> 8);
  dataMsg[len+2] = c & 0xff;

  // now copy final msg with bytestaffing 
  int ppos = 1;
  for (int i = 0; i < (len+3); i++) {
    if (dataMsg[i] == 0x06 or dataMsg[i] == 0x0d or dataMsg[i] == 0x1b or dataMsg[i] == 0x40 or dataMsg[i] == 0x80) {
      physicalMsg[ppos++] = 0x1b;
      physicalMsg[ppos++] = dataMsg[i] ^ 0xff;
    } else {
      physicalMsg[ppos++] = dataMsg[i];
    }
  }
  physicalMsg[ppos++] = 0x0d;
  

  // sending physical msg
  for (int i = 0; i < ppos; i++) {
    kamSer.write(physicalMsg[i]);
  }  
  
}


// takes an application layer message adds address, crc and translates the byte stuffing before sending it with 80h/0dh start+stop
long sendRegRequest( unsigned long reg ) {

  kamSer.flush();  // flush serial buffer - might contain noise
  
  Serial.print(F(">> Get Reg "));
  Serial.print(reg, HEX);
  Serial.print(F(":"));
  if ( debugLevel >= DEBUGLEVEL_REPEAT ) { 
    Serial.println();
  }
    
  // prepare message to send and send it
  byte sendmsg[] = { KAM_GetRegister, 0x01, (reg >> 8), (reg & 0xff) };

  if ( debugLevel >= DEBUGLEVEL_SNDRAW ) { 
    Serial.print(F(">> Reg Request "));
    printMessage( sendmsg, 4 );
  }
    
  sendRequest(sendmsg, 4);

  expectResult = true;
  kamSer.flush();  // flush serial buffer - might contain noise
}


////////////////////////////////////////////////////////////////////////////////////////////////////
//*************************************************************************************************/
//*************************************************************************************************/
//**
//**  Command handling 
//**
//*************************************************************************************************/
//*************************************************************************************************/

////////////////////////////////////////////////////////////////////////////////////////////////////

const char xl100_banner[] PROGMEM = "*************** smartmeter ****************\r\n***\t(c) Johannes Viegener 2017\t***";
const char xl100_help1[] PROGMEM = "  r <id> [<id2>] --> get register value";
const char xl100_help2[] PROGMEM = "  w <data>       --> raw command\r\n  d <level>      --> debug level";
const char xl100_help3[] PROGMEM = "  f <count>      --> repeat factor\r\n  t <ms>         --> timeout for receive";
const char xl100_help4[] PROGMEM = "  q / m / h      --> show status / free mem / help";
// const char xl100_help5[] PROGMEM = "  multi          --> read multiple register values and wait";

const char xl100_eror[] PROGMEM = "***parameter mismatch"; 


const char xl100_printMessage1[] PROGMEM = "\tmessage raw: "; 
const char xl100_printMessage3[] PROGMEM = "  -- end"; 

void printMessage( byte const *appmsg, unsigned int len ) {
  SerialPrintPROG( xl100_printMessage1 );
  Serial.print(len);
  SerialPrintlnPROG( xl100_bytestext );
  Serial.print( F("   --   ") );

  char text[10];
  for (int x = 0; x < len; x++) {
    sprintf( text, stdhexformat, appmsg[x] );
    Serial.print(text );
  }
  SerialPrintlnPROG( xl100_printMessage3 );
}


void printMessageShort( byte const *appmsg, unsigned int len ) {
  Serial.print( F("  ") );

  char text[10];
  for (int x = 0; x < len; x++) {
    sprintf( text, stdhexformat, appmsg[x] );
    Serial.print(text );
  }
}


// handle a list of registers
void getNextRegList( ) {

  if ( currentRegList[0] == 0 ) {
    return;
  }

  sendRegRequest( currentRegList[0] );

  currentRegList[0] += 1;
  if ( currentRegList[0] > currentRegList[1] ) {
    currentRegList[0] = 0;
  }
    
}

void repeatSend() {
  sentRepeatCount++;
  sendRequest( sentLastMsgBuf, sentLastMsgLen );
  expectResult = true;
  kamSer.flush();  // flush serial buffer - might contain noise
}


void commandShowHelp( char *msg ) {

    Serial.println();

    SerialPrintlnPROG( xl100_banner );
    
    if ( msg != NULL ) {
      Serial.println();
      Serial.println( msg );
      Serial.println();
    }

    SerialPrintlnPROG( xl100_help1 );
    SerialPrintlnPROG( xl100_help2 );
    SerialPrintlnPROG( xl100_help3 );
    SerialPrintlnPROG( xl100_help4 );
//    SerialPrintlnPROG( xl100_help5 );
}


void commandShowHelpConst( const PROGMEM char * msg ) {
    commandShowHelp( strcpy_P( globalbuf, msg) );
}


void cShowHelp(int arg_cnt, char **args) {
  if ( expectResult ) {
    return;
  }
  commandShowHelp( NULL );
}





void cShowQueue(int arg_cnt, char **args) {
  if ( expectResult ) {
    return;
  }
  Serial.print( F( ">> Current queue :  rxmsgstart " ) );
  Serial.print(rxmsgstart);
  Serial.print( F( "   rxnext " ) );
  Serial.println(rxnext);

  Serial.print( F( ">> Current repeat factor : " ) );
  Serial.print(sentRepeatFactor);
  Serial.print( F( "  timeout : " ) );
  Serial.print(receiveTimeout);
  Serial.print( F( "  debugLevel : " ) );
  Serial.println(debugLevel);
}

void cShowMem(int arg_cnt, char **args) {
  if ( expectResult ) {
    return;
  }
  Serial.print(F(">> Current memory : "));
  Serial.print(freeRam());
  Serial.println();
}

void cCancel(int arg_cnt, char **args) {
  if ( expectResult ) {
    sentRepeatCount = sentRepeatFactor;
    currentRegList[0] = 0;
    Serial.println(F("\r\n\r\n>> ABORTED "));
  }
}


void cRepeatFactor(int arg_cnt, char **args) {
  if ( expectResult ) {
    return;
  }
  if ( arg_cnt > 2 ) {
    commandShowHelpConst( xl100_eror);
    return;
  }

  if ( arg_cnt == 2 ) {
    int val = cmdStr2Num(args[1], 10 );
    sentRepeatFactor = val;
  }
  Serial.print(F(">> Repeat Factor : "));
  Serial.print(sentRepeatFactor);
  Serial.println();
}


void cDebugLevel(int arg_cnt, char **args) {
  if ( expectResult ) {
    return;
  }
  if ( arg_cnt > 2 ) {
    commandShowHelpConst( xl100_eror);
    return;
  }

  if ( arg_cnt == 2 ) {
    int val = cmdStr2Num(args[1], 10 );
    debugLevel = val;
    if ( debugLevel > MAX_DEBUGLEVEL ) 
      debugLevel = MAX_DEBUGLEVEL;
  }
  Serial.print(F(">> Debug level : "));
  Serial.print(debugLevel);
  Serial.println();
}


void cReceiveTimeout(int arg_cnt, char **args) {
  if ( expectResult ) {
    return;
  }
  if ( arg_cnt > 2 ) {
    commandShowHelpConst( xl100_eror);
    return;
  }

  if ( arg_cnt == 2 ) {
    int val = cmdStr2Num(args[1], 10 );
    receiveTimeout = val;
  }
  Serial.print(F(">> Receive Timeout : "));
  Serial.print(receiveTimeout);
  Serial.println();
}



/*
void cReadReg(int arg_cnt, char **args) {
  if ( expectResult ) {
    return;
  }
  // poll the Kamstrup registers for data 
  for (int kreg = 0; kreg < NUMREGS; kreg++) {
    kamReadReg(kreg);
    delay(100);
  } 
  
}
*/


void cSendRaw(int arg_cnt, char **args) {
  if ( expectResult ) {
    return;
  }

  if ( arg_cnt < 2 ) {
    commandShowHelpConst( xl100_eror);
    return;
  }

  byte sendmsg[ arg_cnt*2 ];
  int spos = 0;

  Serial.print(F(">> Send Raw "));
  for ( int i=1; i<arg_cnt; i++ ) {
    Serial.print(args[i]);
    Serial.print(F(":"));
    unsigned long val = cmdStr2Num(args[i], 16 );
    if ( strlen( args[i] ) > 2 ) {
      sendmsg[spos++] = val>>8;
      sendmsg[spos++] = val & 0xff;
    } else {
      sendmsg[spos++] = val & 0xff;
    }
  }
  if ( debugLevel >= DEBUGLEVEL_REPEAT ) { 
    Serial.println();
  }

  if ( debugLevel >= DEBUGLEVEL_SNDRAW ) { 
    Serial.print(F(">> Raw Request "));
    printMessage( sendmsg, spos );
  }
  sendRequest(sendmsg, spos);

  expectResult = true;
  kamSer.flush();  // flush serial buffer - might contain noise
}


void cRegList(int arg_cnt, char **args) {
  if ( expectResult ) {
    return;
  }
  if ( arg_cnt < 2 ) {
    commandShowHelpConst( xl100_eror);
    return;
  }

  unsigned long reg1 = cmdStr2Num(args[1], 16 );
  unsigned long reg2 = reg1;
  if (  arg_cnt > 2 ) {
    reg2 = cmdStr2Num(args[2], 16 );
  }

  currentRegList[0] = 0;
  currentRegList[1] = 0;
  
  if ( reg2 < reg1 ) {
    Serial.print(F("\r\n >>Err: end range smaller than begin - " ));
    sprintf( globalbuf, stdhexformat, reg1 );
    Serial.print( globalbuf );
    Serial.print(F(" - "));
    sprintf( globalbuf, stdhexformat, reg2 );
    Serial.println( globalbuf );
    return;
  }
  
  if (  arg_cnt > 2 ) {
    if ( debugLevel >= DEBUGLEVEL_START ) { 
      Serial.print(F(">> Get Reg "));
      Serial.print(reg1, HEX);
      Serial.print(F(" : "));
      Serial.print(reg2, HEX);
      Serial.println();
    }
  }

  currentRegList[0] = reg1;
  currentRegList[1] = reg2;

  getNextRegList();
}


void commandSetup() {

  // Setup commands for steering animation
  cmdInit( &Serial );
  cmdAdd( "h", cShowHelp );
  cmdAdd( "m", cShowMem );
  cmdAdd( "q", cShowQueue );
  cmdAdd( "c", cCancel );
  
  cmdAdd( "f", cRepeatFactor );
  cmdAdd( "t", cReceiveTimeout );
  cmdAdd( "d", cDebugLevel );
  
  cmdAdd( "r", cRegList );
  cmdAdd( "w", cSendRaw );
  
  // cmdAdd( "multi", cReadReg );
  
  cmdSetHelp( commandShowHelp );  
} 

/***********************************************************************************************************************************/
/***********************************************************************************************************************************/
/**                                                                                                                               **/
/**  decoder
/**                                                                                                                               **/
/***********************************************************************************************************************************/
/***********************************************************************************************************************************/


// takes an application layer message decodes get register responses
void decodeGetRegister( byte const *appmsg, unsigned int len ) {
  int ptr = 0;
  
  if ( len < 2 ) {
    Serial.println(F(" -- Register not existing"));
    return;
  }

  // 0x10 is already checked so skip byte 1
  ptr++;

  // multiple register not yet supported - not supported on kamstrup 382?
/*  
  if ( appmsg[ptr] != 0x01 ) {
    Serial.print(F("\r\n >>Err: Multiple register values not supported -  "));
    Serial.println(appmsg[ptr],HEX);
  }
  ptr++;
*/

  ptr = decodeSingleRegister( appmsg, len, ptr );
}


// takes an application layer message decodes a signle
long decodeSingleRegister( byte const *appmsg, unsigned int len,  int ptr ) {
  byte numBytes, v;
  
  if ( (len-ptr) < 4  ) {
    // regid-2 numbytes exp-sign 
    Serial.println(F("\r\n>> Err: Minimum length for register header missing "));
    return -1;
  }
  
  word regId = ( appmsg[ptr++] << 8 ) + appmsg[ptr++];

  byte regUnit = appmsg[ptr++];

  // handle float value
  numBytes = appmsg[ptr++];

  // sign and exp
  v = appmsg[ptr++];

  if ( (len-ptr) < numBytes  ) {
    Serial.println(F("\r\n>> Err: Minimum length for register value missing "));
    return -1;
  }
    
  // start output of reg value
  Serial.print(F(" -- Register "));
  Serial.print(regId, HEX);
  Serial.print(F("h = "));
  
  // start eval based on specific units
  if ( regUnit == 54 ) {      // ASCII
    for (int i = 0; i < numBytes; i++) {
      globalbuf[i]= appmsg[ptr++];
    }
    globalbuf[numBytes]= 0;
    
    Serial.print(F("text("));
    Serial.print(numBytes);
    Serial.print(F("):"));
    Serial.print(globalbuf);
    Serial.print(F(": "));
    
  } else {

    int expo = v & 0x3f;
    bool signexpo = ( v & 0x40 );
    bool signmant = ( v & 0x80 );
  
    long mant = 0;
    for (int i = 0; i < numBytes; i++) {
      mant <<= 8;
      mant |= appmsg[ptr++];
    }
    if ( signmant )
      mant = - mant;
  
    // calc final value
    double value = mant;
    for (int i = 0; i < expo; i++) {
      if ( signexpo ) {
        value /= 10;
      } else {
        value *= 10;
      }
    }

    if ( ( regUnit >= 47 ) && ( regUnit <= 50 ) ) {      // clock /   yy:mm:dd / yyyy:mm:dd / date3
      long m100 = mant/100;
      if ( regUnit == 49 ) {
        sprintf( globalbuf, "%2.2u.%2.2u.%4.4u ", mant%100, m100%100, m100/100 );
      } else if ( regUnit == 50 ) {
        sprintf( globalbuf, "%2.2d.%2.2d ", mant%100, m100 );
      } else if ( regUnit == 48 ) {
        sprintf( globalbuf, "%2.2ld.%2.2ld.%2.2ld ", (mant%100), m100%100, (m100/100) );
        
      } else {
        sprintf( globalbuf, "%2.2ld:%2.2ld:%2.2ld ", (m100/100), m100%100, mant%100 );
      }
      Serial.print(globalbuf);
    } else {
      Serial.print(value);
      Serial.print(" ");
    }
  }

  if ( regUnit > MAX_UNITS ){
    Serial.print(F(" unknown unit : "));  
    Serial.print(regUnit);
  } else {
    Serial.print(KAM_units[regUnit]);
  }
  Serial.println();

  return ptr;
}





