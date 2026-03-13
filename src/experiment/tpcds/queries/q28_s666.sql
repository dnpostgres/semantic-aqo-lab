select  *
from (select avg(ss_list_price) B1_LP
            ,count(ss_list_price) B1_CNT
            ,count(distinct ss_list_price) B1_CNTD
      from store_sales
      where ss_quantity between 0 and 5
        and (ss_list_price between 67 and 67+10 
             or ss_coupon_amt between 4313 and 4313+1000
             or ss_wholesale_cost between 73 and 73+20)) B1,
     (select avg(ss_list_price) B2_LP
            ,count(ss_list_price) B2_CNT
            ,count(distinct ss_list_price) B2_CNTD
      from store_sales
      where ss_quantity between 6 and 10
        and (ss_list_price between 59 and 59+10
          or ss_coupon_amt between 9621 and 9621+1000
          or ss_wholesale_cost between 67 and 67+20)) B2,
     (select avg(ss_list_price) B3_LP
            ,count(ss_list_price) B3_CNT
            ,count(distinct ss_list_price) B3_CNTD
      from store_sales
      where ss_quantity between 11 and 15
        and (ss_list_price between 83 and 83+10
          or ss_coupon_amt between 2787 and 2787+1000
          or ss_wholesale_cost between 56 and 56+20)) B3,
     (select avg(ss_list_price) B4_LP
            ,count(ss_list_price) B4_CNT
            ,count(distinct ss_list_price) B4_CNTD
      from store_sales
      where ss_quantity between 16 and 20
        and (ss_list_price between 97 and 97+10
          or ss_coupon_amt between 8224 and 8224+1000
          or ss_wholesale_cost between 38 and 38+20)) B4,
     (select avg(ss_list_price) B5_LP
            ,count(ss_list_price) B5_CNT
            ,count(distinct ss_list_price) B5_CNTD
      from store_sales
      where ss_quantity between 21 and 25
        and (ss_list_price between 128 and 128+10
          or ss_coupon_amt between 12779 and 12779+1000
          or ss_wholesale_cost between 25 and 25+20)) B5,
     (select avg(ss_list_price) B6_LP
            ,count(ss_list_price) B6_CNT
            ,count(distinct ss_list_price) B6_CNTD
      from store_sales
      where ss_quantity between 26 and 30
        and (ss_list_price between 160 and 160+10
          or ss_coupon_amt between 12067 and 12067+1000
          or ss_wholesale_cost between 66 and 66+20)) B6
limit 100;

