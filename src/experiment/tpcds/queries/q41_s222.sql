select  distinct(i_product_name)
 from item i1
 where i_manufact_id between 707 and 707+40 
   and (select count(*) as item_cnt
        from item
        where (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'burnished' or i_color = 'aquamarine') and 
        (i_units = 'Bundle' or i_units = 'Lb') and
        (i_size = 'economy' or i_size = 'extra large')
        ) or
        (i_category = 'Women' and
        (i_color = 'peach' or i_color = 'red') and
        (i_units = 'Dozen' or i_units = 'Pound') and
        (i_size = 'medium' or i_size = 'small')
        ) or
        (i_category = 'Men' and
        (i_color = 'burlywood' or i_color = 'honeydew') and
        (i_units = 'Cup' or i_units = 'Ton') and
        (i_size = 'large' or i_size = 'N/A')
        ) or
        (i_category = 'Men' and
        (i_color = 'grey' or i_color = 'cornflower') and
        (i_units = 'Box' or i_units = 'Oz') and
        (i_size = 'economy' or i_size = 'extra large')
        ))) or
       (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'chartreuse' or i_color = 'ghost') and 
        (i_units = 'Case' or i_units = 'Bunch') and
        (i_size = 'economy' or i_size = 'extra large')
        ) or
        (i_category = 'Women' and
        (i_color = 'khaki' or i_color = 'coral') and
        (i_units = 'Dram' or i_units = 'Tsp') and
        (i_size = 'medium' or i_size = 'small')
        ) or
        (i_category = 'Men' and
        (i_color = 'pale' or i_color = 'moccasin') and
        (i_units = 'Gram' or i_units = 'N/A') and
        (i_size = 'large' or i_size = 'N/A')
        ) or
        (i_category = 'Men' and
        (i_color = 'chocolate' or i_color = 'pink') and
        (i_units = 'Tbl' or i_units = 'Gross') and
        (i_size = 'economy' or i_size = 'extra large')
        )))) > 0
 order by i_product_name
 limit 100;

