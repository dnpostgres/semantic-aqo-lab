select  distinct(i_product_name)
 from item i1
 where i_manufact_id between 974 and 974+40 
   and (select count(*) as item_cnt
        from item
        where (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'turquoise' or i_color = 'blush') and 
        (i_units = 'Gram' or i_units = 'Pallet') and
        (i_size = 'petite' or i_size = 'medium')
        ) or
        (i_category = 'Women' and
        (i_color = 'midnight' or i_color = 'steel') and
        (i_units = 'Dram' or i_units = 'Cup') and
        (i_size = 'small' or i_size = 'large')
        ) or
        (i_category = 'Men' and
        (i_color = 'lemon' or i_color = 'brown') and
        (i_units = 'Bunch' or i_units = 'Pound') and
        (i_size = 'economy' or i_size = 'extra large')
        ) or
        (i_category = 'Men' and
        (i_color = 'burnished' or i_color = 'orchid') and
        (i_units = 'Bundle' or i_units = 'Each') and
        (i_size = 'petite' or i_size = 'medium')
        ))) or
       (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'navy' or i_color = 'cornflower') and 
        (i_units = 'Carton' or i_units = 'Gross') and
        (i_size = 'petite' or i_size = 'medium')
        ) or
        (i_category = 'Women' and
        (i_color = 'honeydew' or i_color = 'linen') and
        (i_units = 'Dozen' or i_units = 'Case') and
        (i_size = 'small' or i_size = 'large')
        ) or
        (i_category = 'Men' and
        (i_color = 'spring' or i_color = 'burlywood') and
        (i_units = 'Lb' or i_units = 'N/A') and
        (i_size = 'economy' or i_size = 'extra large')
        ) or
        (i_category = 'Men' and
        (i_color = 'ivory' or i_color = 'plum') and
        (i_units = 'Tbl' or i_units = 'Box') and
        (i_size = 'petite' or i_size = 'medium')
        )))) > 0
 order by i_product_name
 limit 100;

