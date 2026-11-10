// Parameter-set helpers. k = set + 2.
function [2:0] mlkem_k;
    input [1:0] set;
    begin
        mlkem_k = {1'b0, set} + 3'd2;
    end
endfunction

function [1:0] mlkem_eta1;
    input [2:0] k;
    begin
        mlkem_eta1 = (k == 3'd2) ? 2'd3 : 2'd2;
    end
endfunction

function [3:0] mlkem_du;
    input [2:0] k;
    begin
        mlkem_du = (k == 3'd4) ? 4'd11 : 4'd10;
    end
endfunction

function [3:0] mlkem_dv;
    input [2:0] k;
    begin
        mlkem_dv = (k == 3'd4) ? 4'd5 : 4'd4;
    end
endfunction

function [11:0] mlkem_mod_add;
    input [11:0] a;
    input [11:0] b;
    reg [12:0] s;
    begin
        s = a + b;
        mlkem_mod_add = (s >= 13'd3329) ? s - 13'd3329 : s[11:0];
    end
endfunction

function [11:0] mlkem_mod_sub;
    input [11:0] a;
    input [11:0] b;
    begin
        mlkem_mod_sub = (a >= b) ? a - b : a + 12'd3329 - b;
    end
endfunction

// Decompress_d(y) = round(q * y / 2^d) for the two d values of u (10, 11):
// a 2-way select, no variable shift
function [11:0] mlkem_decompress_u;
    input [10:0] y;
    input d11;
    reg [22:0] t;
    begin
        t = ({12'd0, y} << 11) + ({12'd0, y} << 10) + ({12'd0, y} << 8) + {12'd0, y};
        mlkem_decompress_u = d11 ? ((t + 23'd1024) >> 11) : ((t + 23'd512) >> 10);
    end
endfunction

// Decompress_d for the two d values of v (4, 5)
function [11:0] mlkem_decompress_v;
    input [10:0] y;
    input d5;
    reg [22:0] t;
    begin
        t = ({12'd0, y} << 11) + ({12'd0, y} << 10) + ({12'd0, y} << 8) + {12'd0, y};
        mlkem_decompress_v = d5 ? ((t + 23'd16) >> 5) : ((t + 23'd8) >> 4);
    end
endfunction

// Basemul twiddles gamma_i * 2^16 mod q, gamma_i = 17^(2*BitRev7(i)+1)
function [11:0] mlkem_gamma_r;
    input [6:0] i;
    begin
        case (i)
            7'd0: mlkem_gamma_r = 12'd2226;
            7'd1: mlkem_gamma_r = 12'd1103;
            7'd2: mlkem_gamma_r = 12'd430;
            7'd3: mlkem_gamma_r = 12'd2899;
            7'd4: mlkem_gamma_r = 12'd555;
            7'd5: mlkem_gamma_r = 12'd2774;
            7'd6: mlkem_gamma_r = 12'd843;
            7'd7: mlkem_gamma_r = 12'd2486;
            7'd8: mlkem_gamma_r = 12'd2078;
            7'd9: mlkem_gamma_r = 12'd1251;
            7'd10: mlkem_gamma_r = 12'd871;
            7'd11: mlkem_gamma_r = 12'd2458;
            7'd12: mlkem_gamma_r = 12'd1550;
            7'd13: mlkem_gamma_r = 12'd1779;
            7'd14: mlkem_gamma_r = 12'd105;
            7'd15: mlkem_gamma_r = 12'd3224;
            7'd16: mlkem_gamma_r = 12'd422;
            7'd17: mlkem_gamma_r = 12'd2907;
            7'd18: mlkem_gamma_r = 12'd587;
            7'd19: mlkem_gamma_r = 12'd2742;
            7'd20: mlkem_gamma_r = 12'd177;
            7'd21: mlkem_gamma_r = 12'd3152;
            7'd22: mlkem_gamma_r = 12'd3094;
            7'd23: mlkem_gamma_r = 12'd235;
            7'd24: mlkem_gamma_r = 12'd3038;
            7'd25: mlkem_gamma_r = 12'd291;
            7'd26: mlkem_gamma_r = 12'd2869;
            7'd27: mlkem_gamma_r = 12'd460;
            7'd28: mlkem_gamma_r = 12'd1574;
            7'd29: mlkem_gamma_r = 12'd1755;
            7'd30: mlkem_gamma_r = 12'd1653;
            7'd31: mlkem_gamma_r = 12'd1676;
            7'd32: mlkem_gamma_r = 12'd3083;
            7'd33: mlkem_gamma_r = 12'd246;
            7'd34: mlkem_gamma_r = 12'd778;
            7'd35: mlkem_gamma_r = 12'd2551;
            7'd36: mlkem_gamma_r = 12'd1159;
            7'd37: mlkem_gamma_r = 12'd2170;
            7'd38: mlkem_gamma_r = 12'd3182;
            7'd39: mlkem_gamma_r = 12'd147;
            7'd40: mlkem_gamma_r = 12'd2552;
            7'd41: mlkem_gamma_r = 12'd777;
            7'd42: mlkem_gamma_r = 12'd1483;
            7'd43: mlkem_gamma_r = 12'd1846;
            7'd44: mlkem_gamma_r = 12'd2727;
            7'd45: mlkem_gamma_r = 12'd602;
            7'd46: mlkem_gamma_r = 12'd1119;
            7'd47: mlkem_gamma_r = 12'd2210;
            7'd48: mlkem_gamma_r = 12'd1739;
            7'd49: mlkem_gamma_r = 12'd1590;
            7'd50: mlkem_gamma_r = 12'd644;
            7'd51: mlkem_gamma_r = 12'd2685;
            7'd52: mlkem_gamma_r = 12'd2457;
            7'd53: mlkem_gamma_r = 12'd872;
            7'd54: mlkem_gamma_r = 12'd349;
            7'd55: mlkem_gamma_r = 12'd2980;
            7'd56: mlkem_gamma_r = 12'd418;
            7'd57: mlkem_gamma_r = 12'd2911;
            7'd58: mlkem_gamma_r = 12'd329;
            7'd59: mlkem_gamma_r = 12'd3000;
            7'd60: mlkem_gamma_r = 12'd3173;
            7'd61: mlkem_gamma_r = 12'd156;
            7'd62: mlkem_gamma_r = 12'd3254;
            7'd63: mlkem_gamma_r = 12'd75;
            7'd64: mlkem_gamma_r = 12'd817;
            7'd65: mlkem_gamma_r = 12'd2512;
            7'd66: mlkem_gamma_r = 12'd1097;
            7'd67: mlkem_gamma_r = 12'd2232;
            7'd68: mlkem_gamma_r = 12'd603;
            7'd69: mlkem_gamma_r = 12'd2726;
            7'd70: mlkem_gamma_r = 12'd610;
            7'd71: mlkem_gamma_r = 12'd2719;
            7'd72: mlkem_gamma_r = 12'd1322;
            7'd73: mlkem_gamma_r = 12'd2007;
            7'd74: mlkem_gamma_r = 12'd2044;
            7'd75: mlkem_gamma_r = 12'd1285;
            7'd76: mlkem_gamma_r = 12'd1864;
            7'd77: mlkem_gamma_r = 12'd1465;
            7'd78: mlkem_gamma_r = 12'd384;
            7'd79: mlkem_gamma_r = 12'd2945;
            7'd80: mlkem_gamma_r = 12'd2114;
            7'd81: mlkem_gamma_r = 12'd1215;
            7'd82: mlkem_gamma_r = 12'd3193;
            7'd83: mlkem_gamma_r = 12'd136;
            7'd84: mlkem_gamma_r = 12'd1218;
            7'd85: mlkem_gamma_r = 12'd2111;
            7'd86: mlkem_gamma_r = 12'd1994;
            7'd87: mlkem_gamma_r = 12'd1335;
            7'd88: mlkem_gamma_r = 12'd2455;
            7'd89: mlkem_gamma_r = 12'd874;
            7'd90: mlkem_gamma_r = 12'd220;
            7'd91: mlkem_gamma_r = 12'd3109;
            7'd92: mlkem_gamma_r = 12'd2142;
            7'd93: mlkem_gamma_r = 12'd1187;
            7'd94: mlkem_gamma_r = 12'd1670;
            7'd95: mlkem_gamma_r = 12'd1659;
            7'd96: mlkem_gamma_r = 12'd2144;
            7'd97: mlkem_gamma_r = 12'd1185;
            7'd98: mlkem_gamma_r = 12'd1799;
            7'd99: mlkem_gamma_r = 12'd1530;
            7'd100: mlkem_gamma_r = 12'd2051;
            7'd101: mlkem_gamma_r = 12'd1278;
            7'd102: mlkem_gamma_r = 12'd794;
            7'd103: mlkem_gamma_r = 12'd2535;
            7'd104: mlkem_gamma_r = 12'd1819;
            7'd105: mlkem_gamma_r = 12'd1510;
            7'd106: mlkem_gamma_r = 12'd2475;
            7'd107: mlkem_gamma_r = 12'd854;
            7'd108: mlkem_gamma_r = 12'd2459;
            7'd109: mlkem_gamma_r = 12'd870;
            7'd110: mlkem_gamma_r = 12'd478;
            7'd111: mlkem_gamma_r = 12'd2851;
            7'd112: mlkem_gamma_r = 12'd3221;
            7'd113: mlkem_gamma_r = 12'd108;
            7'd114: mlkem_gamma_r = 12'd3021;
            7'd115: mlkem_gamma_r = 12'd308;
            7'd116: mlkem_gamma_r = 12'd996;
            7'd117: mlkem_gamma_r = 12'd2333;
            7'd118: mlkem_gamma_r = 12'd991;
            7'd119: mlkem_gamma_r = 12'd2338;
            7'd120: mlkem_gamma_r = 12'd958;
            7'd121: mlkem_gamma_r = 12'd2371;
            7'd122: mlkem_gamma_r = 12'd1869;
            7'd123: mlkem_gamma_r = 12'd1460;
            7'd124: mlkem_gamma_r = 12'd1522;
            7'd125: mlkem_gamma_r = 12'd1807;
            7'd126: mlkem_gamma_r = 12'd1628;
            7'd127: mlkem_gamma_r = 12'd1701;
            default: mlkem_gamma_r = 12'd0;
        endcase
    end
endfunction
